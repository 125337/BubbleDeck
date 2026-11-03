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
#import "../Core/TDNet.h"
#import "../Core/TDLicense.h"
#import "../Engine/TDPackLoader.h"
#import "../Engine/TDBubbleEngine.h"
#import "../Engine/TDZip.h"
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

// ────── 在线包：状态与下载器 ──────

static NSArray<NSDictionary *> *s_onlinePacks = nil;  // /packs 列表（nil = 未拉取）
static NSString *s_downloading = nil;                 // 正在下载的包名
static NSString *s_dlKey = nil;                       // 当前下载任务的 .bdpack 密钥（/download 下发）
static float s_dlProgress = 0;
static NSMutableDictionary<NSString *, UIButton *> *s_dlButtons;

static void BDBuildPage(UIViewController *vc);          // 前置声明（见下）
static void BDFetchOnlinePacks(UIViewController *vc);

static NSString *BDFileSize(long long bytes) {
    if (bytes >= 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / 1024.0 / 1024.0];
    if (bytes >= 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%lld B", bytes];
}

// 进度写回当前下载按钮（页面重建后按钮会被 s_dlButtons 换新）
static void BDUpdateProgressButton(void) {
    UIButton *b = s_dlButtons[s_downloading];
    if (b) {
        b.enabled = NO;
        [b setTitle:[NSString stringWithFormat:@"%.0f%%", s_dlProgress * 100]
           forState:UIControlStateNormal];
    }
}

// .bdpack 下载器：进度 → md5 校验 → 解密解压落盘。同一时刻只跑一个任务。
@interface BDDownloader : NSObject <NSURLSessionDownloadDelegate>
+ (instancetype)shared;
- (void)fetchPack:(NSString *)name url:(NSString *)url md5:(NSString *)md5
       completion:(void (^)(BOOL ok, NSString *message))cb;   // 主线程回调
@end

@implementation BDDownloader {
    NSURLSession *_session;
    void (^_cb)(BOOL, NSString *);
    NSString *_name, *_md5;
    BOOL _done;
}

+ (instancetype)shared {
    static BDDownloader *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [BDDownloader new]; });
    return d;
}

- (instancetype)init {
    if (self = [super init]) {
        _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                 delegate:self delegateQueue:nil];
    }
    return self;
}

- (void)fetchPack:(NSString *)name url:(NSString *)url md5:(NSString *)md5
       completion:(void (^)(BOOL, NSString *))cb {
    _cb = cb;
    _name = name;
    _md5 = md5.lowercaseString;
    _done = NO;
    [[_session downloadTaskWithURL:[NSURL URLWithString:url]] resume];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
           didWriteData:(int64_t)bytesWritten totalBytesWritten:(int64_t)total
totalBytesExpectedToWrite:(int64_t)expect {
    dispatch_async(dispatch_get_main_queue(), ^{
        s_dlProgress = expect > 0 ? (float)total / (float)expect : 0;
        BDUpdateProgressButton();
    });
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
didFinishDownloadingToURL:(NSURL *)location {
    NSData *data = [NSData dataWithContentsOfURL:location];
    NSError *zipErr = nil;
    NSString *err = nil;
    if (!data.length) err = @"下载内容为空";
    else if (![TDZip verifyMd5:_md5 ofData:data]) err = @"文件校验失败（md5 不符），请重试";
    else if (![TDZip installBdpackData:data key:s_dlKey packName:_name error:&zipErr])
        err = zipErr.localizedDescription ?: @"安装失败";

    if (err) TDLog(@"LIC", @"[Download] 失败: %@ - %@", _name, err);
    else TDLog(@"LIC", @"[Download] 安装完成: %@", _name);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_done) return;
        self->_done = YES;
        void (^cb)(BOOL, NSString *) = self->_cb;
        self->_cb = nil;
        if (cb) cb(err == nil, err ?: @"");
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_done) return;
        self->_done = YES;
        void (^cb)(BOOL, NSString *) = self->_cb;
        self->_cb = nil;
        if (cb) cb(NO, @"下载失败：网络异常");
    });
}

@end

// ────── 页面构建（viewWillAppear 全量重建，量小保证状态新鲜） ──────

static const void *kBDBottomKey = "bottom";

// 工具行（重新加载按钮 / 日志开关），复用一个底部容器
static void BDBuildPage(UIViewController *vc) {
    // 移除旧 UI（重建）
    for (UIView *sub in vc.view.subviews) [sub removeFromSuperview];
    objc_setAssociatedObject(vc, kBDBottomKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!s_dlButtons) s_dlButtons = [NSMutableDictionary dictionary];
    [s_dlButtons removeAllObjects];   // 旧按钮引用换新（重建后进度写最新按钮）

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

    // ── 激活状态卡 ──
    if ([TDLicense isActiveNow]) {
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 64)];
        card.backgroundColor = BDCardBg();
        card.layer.cornerRadius = 15;
        if (@available(iOS 13.0, *)) card.layer.cornerCurve = kCACornerCurveContinuous;
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, wIn - 32, 22)];
        t.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        t.text = @"✓ 已激活";
        [card addSubview:t];
        UILabel *s2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 36, wIn - 32, 16)];
        s2.font = [UIFont systemFontOfSize:12];
        s2.textColor = BDSecondaryText();
        s2.text = [NSString stringWithFormat:@"永久授权 · 设备尾号 %@", [TDLicense deviceTail]];
        [card addSubview:s2];
        [scroll addSubview:card];
        y += 64 + 12;
    } else {
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 76)];
        card.backgroundColor = BDCardBg();
        card.layer.cornerRadius = 15;
        if (@available(iOS 13.0, *)) card.layer.cornerCurve = kCACornerCurveContinuous;
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 15, wIn - 130, 22)];
        t.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        t.text = @"插件未激活";
        [card addSubview:t];
        UILabel *s2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 41, wIn - 130, 18)];
        s2.font = [UIFont systemFontOfSize:12];
        s2.textColor = BDSecondaryText();
        s2.text = @"输入卡密解锁在线气泡包";
        [card addSubview:s2];
        UIButton *act = [UIButton buttonWithType:UIButtonTypeSystem];
        act.frame = CGRectMake(wIn - 96, 21, 80, 34);
        act.layer.cornerRadius = 10;
        if (@available(iOS 13.0, *)) act.backgroundColor = [UIColor systemBlueColor];
        else act.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
        act.tintColor = [UIColor whiteColor];
        act.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        [act setTitle:@"激活" forState:UIControlStateNormal];
        [act addTarget:vc action:NSSelectorFromString(@"bdActivateTap:")
       forControlEvents:UIControlEventTouchUpInside];
        [card addSubview:act];
        [scroll addSubview:card];
        y += 76 + 12;
    }

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

    // ── 在线包区（仅已激活显示；未激活什么都不渲染） ──
    if ([TDLicense isActiveNow]) {
        UILabel *sec = [[UILabel alloc] initWithFrame:CGRectMake(15, y + 2, wIn, 18)];
        sec.font = [UIFont systemFontOfSize:13];
        sec.textColor = BDSecondaryText();
        sec.text = @"在线气泡包";
        [scroll addSubview:sec];
        y += 26;

        if (!s_onlinePacks) {
            // 列表未拉取：静默拉取，回来重建页面
            BDFetchOnlinePacks(vc);
            UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(15, y, wIn, 40)];
            hint.font = [UIFont systemFontOfSize:13];
            hint.textColor = BDSecondaryText();
            hint.textAlignment = NSTextAlignmentCenter;
            hint.text = @"正在获取在线包列表…";
            [scroll addSubview:hint];
            y += 40 + 12;
        } else if (s_onlinePacks.count == 0) {
            UILabel *hint = [[UILabel alloc] initWithFrame:CGRectMake(15, y, wIn, 40)];
            hint.font = [UIFont systemFontOfSize:13];
            hint.textColor = BDSecondaryText();
            hint.textAlignment = NSTextAlignmentCenter;
            hint.text = @"暂无可下载的气泡包";
            [scroll addSubview:hint];
            y += 40 + 12;
        } else {
            NSSet<NSString *> *installed = [NSSet setWithArray:packs];
            BOOL highlighted = NO;
            for (NSDictionary *p in s_onlinePacks) {
                NSString *name = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"";
                if (!name.length) continue;
                BOOL has = [installed containsObject:name];
                BOOL busy = [s_downloading isEqualToString:name];
                BOOL firstTodo = !has && !busy && !highlighted && !s_downloading;

                UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 64)];
                card.backgroundColor = BDCardBg();
                card.layer.cornerRadius = 15;
                if (@available(iOS 13.0, *)) {
                    card.layer.cornerCurve = kCACornerCurveContinuous;
                    if (firstTodo) {
                        card.layer.borderWidth = 1.5;   // 引导下载：高亮第一个未安装包
                        card.layer.borderColor = [UIColor systemBlueColor].CGColor;
                    }
                }

                UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(16, 11, wIn - 150, 20)];
                nm.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
                nm.text = name;
                [card addSubview:nm];

                UILabel *sb = [[UILabel alloc] initWithFrame:CGRectMake(16, 34, wIn - 150, 16)];
                sb.font = [UIFont systemFontOfSize:12];
                sb.textColor = BDSecondaryText();
                sb.text = [NSString stringWithFormat:@"v%@ · %@",
                           p[@"version"] ?: @"1.0", BDFileSize([p[@"size"] longLongValue])];
                [card addSubview:sb];

                UIButton *dl = [UIButton buttonWithType:UIButtonTypeSystem];
                dl.frame = CGRectMake(wIn - 92, 16, 76, 32);
                dl.layer.cornerRadius = 10;
                dl.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
                if (has) {
                    [dl setTitle:@"已安装" forState:UIControlStateNormal];
                    dl.enabled = NO;
                    if (@available(iOS 13.0, *)) dl.backgroundColor = [UIColor tertiarySystemFillColor];
                    else dl.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
                } else if (busy) {
                    [dl setTitle:[NSString stringWithFormat:@"%.0f%%", s_dlProgress * 100]
                        forState:UIControlStateNormal];
                    dl.enabled = NO;
                    if (@available(iOS 13.0, *)) dl.backgroundColor = [UIColor tertiarySystemFillColor];
                    else dl.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
                } else {
                    [dl setTitle:@"下载" forState:UIControlStateNormal];
                    if (@available(iOS 13.0, *)) dl.backgroundColor = [UIColor systemBlueColor];
                    else dl.backgroundColor = [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
                    dl.tintColor = [UIColor whiteColor];
                    objc_setAssociatedObject(dl, "pack", name, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [dl addTarget:vc action:NSSelectorFromString(@"bdDownloadTap:")
                   forControlEvents:UIControlEventTouchUpInside];
                    s_dlButtons[name] = dl;
                }
                [card addSubview:dl];
                [scroll addSubview:card];
                y += 64 + 12;
                if (!has && !busy) highlighted = YES;
            }
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

// ────── 在线包与激活（交互处理） ──────

static BOOL s_fetchingPacks = NO;

// 拉在线包列表；成功重建页面，失败静默（保持 nil，下次进页重试）
static void BDFetchOnlinePacks(UIViewController *vc) {
    if (s_fetchingPacks) return;
    s_fetchingPacks = YES;
    NSString *token = [TDLicense currentToken];
    if (!token.length) { s_fetchingPacks = NO; return; }
    __weak UIViewController *wv = vc;
    [TDNet postPath:@"packs"
               body:@{ @"token"    : token,
                       @"device_id": [TDLicense deviceID] }
         completion:^(NSInteger code, NSString *msg, NSDictionary *data) {
        s_fetchingPacks = NO;
        if (code == 0) {
            id arr = data[@"packs"];
            s_onlinePacks = [arr isKindOfClass:[NSArray class]] ? arr : @[];
            TDLog(@"LIC", @"[Download] 在线包 %lu 个", (unsigned long)s_onlinePacks.count);
        } else if (code == 2001) {
            s_onlinePacks = @[];   // token 失效：不等列表了（startupCheck 会自愈重激活）
        } else {
            return;                // 网络失败：不重建，保留「正在获取」占位到下次进页
        }
        UIViewController *v = wv;
        if (v && v.isViewLoaded && v.view.window) BDBuildPage(v);
    }];
}

// 下载：/download 取 url+md5+key → 下载 → 校验 → 解密解压落盘
static void BDStartDownload(UIViewController *vc, NSString *name) {
    if (s_downloading || !name.length) return;
    NSString *token = [TDLicense currentToken];
    if (!token.length) return;
    s_downloading = name;
    s_dlProgress = 0;
    UIButton *b = s_dlButtons[name];
    if (b) { b.enabled = NO; [b setTitle:@"0%" forState:UIControlStateNormal]; }
    TDLog(@"LIC", @"[Download] 开始: %@", name);

    __weak UIViewController *wv = vc;
    [TDNet postPath:@"download"
               body:@{ @"token"    : token,
                       @"device_id": [TDLicense deviceID],
                       @"name"     : name }
         completion:^(NSInteger code, NSString *msg, NSDictionary *data) {
        UIViewController *v = wv;
        if (code != 0) {
            s_downloading = nil;
            if (v) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"下载失败"
                    message:[TDNet humanMessageForCode:code serverMsg:msg]
                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [v presentViewController:a animated:YES completion:nil];
            }
            return;
        }
        s_dlKey = [data[@"key"] isKindOfClass:[NSString class]] ? data[@"key"] : @"";
        [[BDDownloader shared] fetchPack:name
                                     url:[data[@"url"] isKindOfClass:[NSString class]] ? data[@"url"] : @""
                                     md5:[data[@"md5"] isKindOfClass:[NSString class]] ? data[@"md5"] : @""
                              completion:^(BOOL ok, NSString *message) {
            s_downloading = nil;
            UIViewController *v2 = wv;
            if (v2 && v2.isViewLoaded) {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:
                    ok ? @"下载完成" : @"下载失败"
                    message:ok ? [NSString stringWithFormat:@"「%@」已安装，点击下方卡片即可启用。", name]
                               : message
                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [v2 presentViewController:a animated:YES completion:nil];
                BDBuildPage(v2);   // 新包进本地列表，气泡即刻可用
            }
        }];
    }];
}

// 激活入口：弹窗输入卡密 → /activate → 成功后自动拉在线包列表（高亮引导下载）
static void bdActivateTap(id self, SEL _cmd, UIButton *btn) {
    UIViewController *vc = (UIViewController *)self;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入卡密"
        message:@"卡密格式 XXXX-XXXX-XXXX-XXXX，1 卡 = 1 设备，激活后绑定本机"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"XXXX-XXXX-XXXX-XXXX";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIViewController *wv = vc;
    [alert addAction:[UIAlertAction actionWithTitle:@"激活" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) {
        NSString *card = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!card.length) return;
        TDLog(@"LIC", @"[Activate] 用户提交卡密（尾 4 位: %@）", card.length >= 4 ? [card substringFromIndex:card.length - 4] : card);
        [TDLicense activateCard:card completion:^(BOOL ok, NSString *message) {
            UIViewController *v = wv;
            UIAlertController *done = [UIAlertController alertControllerWithTitle:
                ok ? @"激活成功" : @"激活失败"
                message:ok ? @"已绑定本机，在线气泡包列表已解锁。" : message
                preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *x) {
                if (!ok) return;
                s_onlinePacks = nil;   // 重新拉列表 → 重建页面 → 第一个未安装包高亮
                UIViewController *v2 = wv;
                if (v2 && v2.isViewLoaded) BDBuildPage(v2);
            }]];
            [v presentViewController:done animated:YES completion:nil];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static void bdDownloadTap(id self, SEL _cmd, UIButton *btn) {
    UIViewController *vc = (UIViewController *)self;
    NSString *name = objc_getAssociatedObject(btn, "pack");
    BDStartDownload(vc, name);
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

        // 授权启动自愈（后台异步：verify 报到 → 过期自动重激活 → 闸门状态就位）
        [TDLicense startupCheck];

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
            class_addMethod(entryClass, NSSelectorFromString(@"bdActivateTap:"), (IMP)bdActivateTap, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdDownloadTap:"), (IMP)bdDownloadTap, "v@:@");
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
