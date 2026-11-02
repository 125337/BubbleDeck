//
//  TDBubbleEntry.m
//  BubbleDeck
//
//  极简设置页（V1）：选气泡包 / 重新加载 / 日志开关。
//  机制照搬 ThemeDeck TDPluginEntry（已验证同款流程），运行时创建类对，
//  继承微信基类（MMUIViewController，缺失回退 UIViewController）。
//  注意：MMUIViewController 的 view 延伸到导航栏底下，所有布局从 safeArea 起算。
//

#import "TDBubbleEntry.h"
#import "../Core/TDLog.h"
#import "../Core/TDConfig.h"
#import "../Engine/TDPackLoader.h"
#import "../Engine/TDBubbleEngine.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ────── 基类探测（Mio WPGetBaseClass 同款） ──────
static Class BDGetBaseClass(void) {
    Class cls = objc_getClass("MMUIViewController");
    if (cls) return cls;
    return objc_getClass("UIViewController");
}

// ────── 工具 ──────

static UIColor *BDPageBg(void) {
    if (@available(iOS 13.0, *)) return [UIColor systemBackgroundColor];
    return [UIColor whiteColor];
}

static UIColor *BDCardBg(void) {
    if (@available(iOS 13.0, *)) return [UIColor secondarySystemGroupedBackgroundColor];
    return [UIColor whiteColor];
}

static UIColor *BDSecondaryText(void) {
    if (@available(iOS 13.0, *)) return [UIColor secondaryLabelColor];
    return [UIColor grayColor];
}

static UIColor *BDPlaceholderBg(void) {
    if (@available(iOS 13.0, *)) return [UIColor tertiarySystemFillColor];
    return [UIColor colorWithRed:0.88 green:0.88 blue:0.89 alpha:1.0];
}

// 包图片数：统计解包目录里的位图文件
static NSInteger BDPackImageCount(NSString *dir) {
    NSInteger files = 0;
    NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:dir];
    NSString *rel;
    while ((rel = [en nextObject])) {
        NSString *ext = rel.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
            [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"webp"]) files++;
    }
    return files;
}

// ────── 气泡包卡片 ──────
// packName = nil 表示「微信默认」卡；isActive 决定右侧徽章样式

static UIView *BDMakeCard(CGFloat y, CGFloat w,
                          NSString *packName, NSString *title,
                          NSString *subtitle, UIImage *thumb, BOOL isActive) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 76)];
    card.backgroundColor = BDCardBg();
    card.layer.cornerRadius = 15;
    if (@available(iOS 13.0, *)) card.layer.cornerCurve = kCACornerCurveContinuous;
    if (@available(iOS 13.0, *)) {
        if (isActive) card.layer.borderWidth = 1.5, card.layer.borderColor = [UIColor systemBlueColor].CGColor;
    }

    // 缩略图：48pt 圆角；无图用包名首字占位
    UIView *thumbView;
    CGFloat tx = 14, ty = 14;
    if (thumb) {
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(tx, ty, 48, 48)];
        iv.image = thumb;
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.clipsToBounds = YES;
        thumbView = iv;
    } else {
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(tx, ty, 48, 48)];
        lb.backgroundColor = BDPlaceholderBg();
        lb.textAlignment = NSTextAlignmentCenter;
        lb.font = [UIFont boldSystemFontOfSize:20];
        lb.textColor = BDSecondaryText();
        lb.text = (title.length > 0)
            ? [[title substringToIndex:1] uppercaseString]
            : @"?";
        thumbView = lb;
    }
    thumbView.layer.cornerRadius = 12;
    thumbView.clipsToBounds = YES;
    [card addSubview:thumbView];

    CGFloat textX = tx + 48 + 14;
    CGFloat textW = w - 30 - textX - 70; // 右侧留徽章/箭头区

    UILabel *nameLb = [[UILabel alloc] initWithFrame:CGRectMake(textX, 15, textW, 22)];
    nameLb.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    nameLb.text = title;
    [card addSubview:nameLb];

    UILabel *subLb = [[UILabel alloc] initWithFrame:CGRectMake(textX, 41, textW, 18)];
    subLb.font = [UIFont systemFontOfSize:12];
    subLb.textColor = BDSecondaryText();
    subLb.text = subtitle;
    [card addSubview:subLb];

    if (isActive) {
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(w - 30 - 66, 28, 58, 22)];
        if (@available(iOS 13.0, *)) badge.backgroundColor = [UIColor systemBlueColor];
        else badge.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        badge.textColor = [UIColor whiteColor];
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 11;
        badge.clipsToBounds = YES;
        badge.text = @"使用中";
        [card addSubview:badge];
    } else {
        UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(w - 30 - 34, 0, 20, 76)];
        chevron.text = @"›";
        chevron.font = [UIFont systemFontOfSize:20];
        chevron.textColor = BDSecondaryText();
        chevron.textAlignment = NSTextAlignmentCenter;
        [card addSubview:chevron];
    }

    // 点按目标：包名挂 associated object（nil = 微信默认卡），手势由调用方挂
    objc_setAssociatedObject(card, "pack", packName, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return card;
}

// ────── 页面构建（viewWillAppear 全量重建，量小保证状态新鲜） ──────

static const void *kBDBottomKey = "bottom";

// 工具行（重新加载按钮 / 日志开关），复用一个底部容器
static void BDBuildPage(UIViewController *vc) {
    // 移除旧 UI（重建）
    for (UIView *sub in vc.view.subviews) [sub removeFromSuperview];
    objc_setAssociatedObject(vc, kBDBottomKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat w = vc.view.bounds.size.width;
    CGFloat h = vc.view.bounds.size.height;

    NSArray<NSString *> *packs = [TDConfig availablePacks];
    NSString *active = [TDConfig activePack];
    // 激活名在包列表里不存在 = 配置残留，按未激活处理并清理
    if (active && ![packs containsObject:active]) {
        TDLog(@"DEV", @"[activePack] 指向不存在的包 %@，清理", active);
        [TDConfig setActivePack:nil];
        active = nil;
    }

    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    scroll.showsVerticalScrollIndicator = YES;
    if (@available(iOS 13.0, *)) scroll.automaticallyAdjustsScrollIndicatorInsets = NO;

    // ── 大标题区 ──
    UILabel *big = [[UILabel alloc] initWithFrame:CGRectMake(15, 6, w - 30, 34)];
    big.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    big.text = @"BubbleDeck";
    [scroll addSubview:big];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(15, 44, w - 30, 18)];
    sub.font = [UIFont systemFontOfSize:13];
    sub.textColor = BDSecondaryText();
    sub.text = packs.count
        ? [NSString stringWithFormat:@"v%@ · 已安装 %lu 个气泡包", kTDVersion, (unsigned long)packs.count]
        : [NSString stringWithFormat:@"v%@ · 未安装任何气泡包", kTDVersion];
    [scroll addSubview:sub];

    CGFloat y = 74;
    CGFloat wIn = w - 30;

    // 首卡：微信默认
    {
        UIView *card = BDMakeCard(y, w, nil, @"微信默认",
                                  @"不使用任何气泡包，恢复微信原生气泡",
                                  nil, active == nil);
        objc_setAssociatedObject(card, "pack", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc]
            initWithTarget:vc action:NSSelectorFromString(@"bdCardTap:")];
        [card addGestureRecognizer:gr];
        [scroll addSubview:card];
        y += 76 + 12;
    }

    if (packs.count == 0) {
        // 空状态引导卡
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 92)];
        card.backgroundColor = BDCardBg();
        card.layer.cornerRadius = 15;
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, wIn - 32, 92)];
        lb.font = [UIFont systemFontOfSize:13];
        lb.textColor = BDSecondaryText();
        lb.numberOfLines = 0;
        lb.text = @"将气泡包文件夹放入\nDocuments/BubbleDeck/packs/\n（含 info.json 的目录）\n然后点「重新加载」";
        [card addSubview:lb];
        [scroll addSubview:card];
        y += 92 + 12;
    } else {
        for (NSString *name in packs) {
            NSString *dir = [TDPackLoader packDirForName:name];
            NSString *subtitle = [NSString stringWithFormat:@"%ld 图",
                                  dir ? (long)BDPackImageCount(dir) : 0L];
            UIImage *thumb = dir
                ? [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"icon.png"]]
                : nil;
            BOOL isActive = [active isEqualToString:name];

            UIView *card = BDMakeCard(y, w, name, name, subtitle, thumb, isActive);
            UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc]
                initWithTarget:vc action:NSSelectorFromString(@"bdCardTap:")];
            [card addGestureRecognizer:gr];
            [scroll addSubview:card];
            y += 76 + 12;
        }
    }

    // ── 工具行：重新加载 / 日志开关 ──
    UIView *tools = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 110)];
    tools.backgroundColor = BDCardBg();
    tools.layer.cornerRadius = 15;

    UIButton *reload = [UIButton buttonWithType:UIButtonTypeSystem];
    reload.frame = CGRectMake(16, 12, wIn - 32, 38);
    reload.backgroundColor = [UIColor systemBlueColor];
    reload.layer.cornerRadius = 10;
    reload.tintColor = [UIColor whiteColor];
    reload.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [reload setTitle:@"重新加载" forState:UIControlStateNormal];
    [reload addTarget:vc action:NSSelectorFromString(@"bdReloadTap:")
     forControlEvents:UIControlEventTouchUpInside];
    [tools addSubview:reload];

    UILabel *logLb = [[UILabel alloc] initWithFrame:CGRectMake(16, 62, wIn - 90, 34)];
    logLb.font = [UIFont systemFontOfSize:14];
    logLb.text = @"日志记录";
    [tools addSubview:logLb];

    UISwitch *logSw = [[UISwitch alloc] initWithFrame:CGRectMake(wIn - 66, 63, 51, 31)];
    logSw.on = [_TDLogManager fileLoggingEnabled];
    [logSw addTarget:vc action:NSSelectorFromString(@"bdLogSwitch:")
     forControlEvents:UIControlEventValueChanged];
    objc_setAssociatedObject(logSw, "view", vc, OBJC_ASSOCIATION_ASSIGN);
    [tools addSubview:logSw];

    [scroll addSubview:tools];
    y += 110 + 12;

    // 页脚
    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(0, y + 4, w, 20)];
    foot.font = [UIFont systemFontOfSize:12];
    foot.textColor = BDSecondaryText();
    foot.textAlignment = NSTextAlignmentCenter;
    foot.text = @"BubbleDeck · 本地气泡引擎";
    [scroll addSubview:foot];
    scroll.contentSize = CGSizeMake(w, y + 32);

    [vc.view addSubview:scroll];

    // 方案 B：scroll 四边钉在 safeAreaLayoutGuide 上——导航栏/状态栏/Home 条
    // 高度全由系统维护，内容从 y=0 起画，无快照、无兜底、无双重计算
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor      constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor   constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor  constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.trailingAnchor],
    ]];
}

// ────── 交互处理（注册在类对上的实例方法） ──────

static void bdCardTap(id self, SEL _cmd, UITapGestureRecognizer *gr) {
    UIViewController *vc = (UIViewController *)self;
    NSString *pack = objc_getAssociatedObject(gr.view, "pack");
    NSString *active = [TDConfig activePack];

    if (pack == nil) {
        // 微信默认卡：仅在当前有激活气泡包时提供恢复
        if (!active) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"恢复微信默认"
            message:[NSString stringWithFormat:@"将停用「%@」，恢复微信原生气泡。", active]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"恢复默认" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
            [TDConfig setActivePack:nil];
            TDLog(@"DEV", @"[Pack] 恢复微信默认（原 %@）", active);
            BDBuildPage(vc);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
        return;
    }

    if ([pack isEqualToString:active]) return; // 已在使用，无操作

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"启用气泡包"
        message:[NSString stringWithFormat:@"启用「%@」？\n新打开的聊天页生效。", pack]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"启用" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        [TDConfig setActivePack:pack];
        TDLog(@"DEV", @"[Pack] 激活气泡包: %@", pack);
        BDBuildPage(vc);
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static void bdReloadTap(id self, SEL _cmd, UIButton *btn) {
    UIViewController *vc = (UIViewController *)self;
    [TDBubbleEngine purgeCaches];       // 顺带清负缓存，包内容变更即时生效
    BDBuildPage(vc);
    TDLog(@"DEV", @"[Pack] 重新加载，packs=%@", [TDConfig availablePacks]);
}

static void bdLogSwitch(id self, SEL _cmd, UISwitch *sw) {
    [_TDLogManager setFileLoggingEnabled:sw.on];
    TDLog(@"DEV", @"[Log] 文件日志 %@", sw.on ? @"开" : @"关");
}

// ────── 生命周期 IMP ──────

static void bdEntryViewDidLoad(id self, SEL _cmd) {
    // 调用父类 viewDidLoad
    Method m = class_getInstanceMethod(objc_getClass("UIViewController"), _cmd);
    if (m) ((void (*)(id, SEL))method_getImplementation(m))(self, _cmd);

    ((UIViewController *)self).title = @"BubbleDeck";
    // UI 创建推迟到 viewWillAppear（同 ThemeDeck 防黑屏）
}

static void bdEntryViewWillAppear(id self, SEL _cmd, BOOL animated) {
    Method m = class_getInstanceMethod(objc_getClass("UIViewController"), _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);

    UIViewController *vc = (UIViewController *)self;
    if (@available(iOS 13.0, *)) {
        vc.view.backgroundColor = [UIColor systemBackgroundColor];
    }

    if (vc.view.bounds.size.width < 1) return; // bounds 未就绪，等下次 appear
    BDBuildPage(vc);
}

static void bdEntryViewDidAppear(id self, SEL _cmd, BOOL animated) {
    Method m = class_getInstanceMethod(objc_getClass("UIViewController"), _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);
}

static void bdEntryViewWillDisappear(id self, SEL _cmd, BOOL animated) {
    Method m = class_getInstanceMethod(objc_getClass("UIViewController"), _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);
}

// ────── 安装 ──────

@implementation TDBubbleEntry

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        TDLog(@"DEV", @"TDBubbleEntry install: 气泡 hook + 插件页入口");

        // 启动时包列表锚点（排查 Documents 被外部清理的时间点用）
        TDLog(@"DEV", @"[Pack] install 时已安装: %@", [TDConfig availablePacks]);

        // 1. 气泡引擎 hook
        [TDBubbleEngine installHooks];

        // 2. 插件页注册
        Class pluginsMgrClass = objc_getClass("WCPluginsMgr");
        if (!pluginsMgrClass) {
            TDLog(@"DEV", @"[Entry] WCPluginsMgr not found");
            return;
        }
        id sharedInstance = ((id (*)(id, SEL, ...))objc_msgSend)(
            pluginsMgrClass, NSSelectorFromString(@"sharedInstance"));
        if (!sharedInstance) {
            TDLog(@"DEV", @"[Entry] sharedInstance nil");
            return;
        }

        Class baseClass = BDGetBaseClass();
        TDLogD(@"DEV", @"[Entry] baseClass: %@", NSStringFromClass(baseClass));
        if (!baseClass) {
            TDLog(@"DEV", @"[Entry] base class not found");
            return;
        }

        Class entryClass = objc_getClass("BubbleDeckEntryVC");
        if (!entryClass) {
            entryClass = objc_allocateClassPair(baseClass, "BubbleDeckEntryVC", 0);
            if (!entryClass) {
                TDLog(@"DEV", @"[Entry] BubbleDeckEntryVC create failed");
                return;
            }
            class_addMethod(entryClass, NSSelectorFromString(@"viewDidLoad"), (IMP)bdEntryViewDidLoad, "v@:");
            class_addMethod(entryClass, NSSelectorFromString(@"viewWillAppear:"), (IMP)bdEntryViewWillAppear, "v@:B");
            class_addMethod(entryClass, NSSelectorFromString(@"viewDidAppear:"), (IMP)bdEntryViewDidAppear, "v@:B");
            class_addMethod(entryClass, NSSelectorFromString(@"viewWillDisappear:"), (IMP)bdEntryViewWillDisappear, "v@:B");
            class_addMethod(entryClass, NSSelectorFromString(@"bdCardTap:"), (IMP)bdCardTap, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdReloadTap:"), (IMP)bdReloadTap, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdLogSwitch:"), (IMP)bdLogSwitch, "v@:@");
            objc_registerClassPair(entryClass);
        }

        SEL regSel = NSSelectorFromString(@"registerControllerWithTitle:version:controller:");
        if ([sharedInstance respondsToSelector:regSel]) {
            ((void (*)(id, SEL, NSString *, NSString *, NSString *))objc_msgSend)(
                sharedInstance, regSel, @"BubbleDeck", kTDVersion, @"BubbleDeckEntryVC");
            TDLog(@"DEV", @"[Entry] registered");
        } else {
            TDLog(@"DEV", @"[Entry] registerController not found");
        }
    });
}

@end
