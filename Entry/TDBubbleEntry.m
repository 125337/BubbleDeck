//
//  TDBubbleEntry.m
//  BubbleDeck
//
//  插件页（v0.4.0 四页结构，参考 BubbleBox 信息架构）：
//    主页   = 启用插件总开关 + 三入口（下载气泡/更换气泡/设置中心）+ 兑换激活码
//    商店页 = 只列 owned 包（未下载[下载] / 已下载[已安装]）；未拥有、已失效一律不出现
//    主题页 = 只列已下载且授权有效的包（微信默认 + 本地包），点卡片启用
//    设置页 = 日志开关 / 重新加载 / 关于
//  单 VC 内切页（自绘导航头 + 返回），不依赖微信导航栈。
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

static UIColor *BDTint(void) {
    if (@available(iOS 13.0, *)) return [UIColor systemBlueColor];
    return [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
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

static NSString *BDFileSize(long long bytes) {
    if (bytes >= 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / 1024.0 / 1024.0];
    if (bytes >= 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%lld B", bytes];
}

// ────── 主题页：气泡包卡片 ──────
// packName = nil 表示「微信默认」卡；isActive 决定右侧徽章样式

static UIView *BDMakeCard(CGFloat y, CGFloat w,
                          NSString *packName, NSString *title,
                          NSString *subtitle, UIImage *thumb, BOOL isActive) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 76)];
    card.backgroundColor = BDCardBg();
    card.layer.cornerRadius = 15;
    if (@available(iOS 13.0, *)) card.layer.cornerCurve = kCACornerCurveContinuous;
    if (@available(iOS 13.0, *)) {
        if (isActive) card.layer.borderWidth = 1.5, card.layer.borderColor = BDTint().CGColor;
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
        badge.backgroundColor = BDTint();
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

// ────── 商店页：状态与下载器 ──────

static NSString *s_downloading = nil;                 // 正在下载的包名
static NSString *s_dlKey = nil;                       // 当前下载任务的 .bdpack 密钥（清单下发）
static float s_dlProgress = 0;
static NSMutableDictionary<NSString *, UIButton *> *s_dlButtons;
static BOOL s_fetchingEnts = NO;                      // 报到进行中
static BOOL s_triedFetch = NO;                        // 本次会话是否已尝试报到（防重建循环）

static void BDBuildPage(UIViewController *vc);          // 前置声明（见下）
static void BDFetchEntitlements(UIViewController *vc);

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

// ────── 页面框架（viewWillAppear 全量重建，量小保证状态新鲜） ──────

// 当前页：0 主页 / 1 商店 / 2 主题 / 3 设置
static NSInteger s_page = 0;

static UIScrollView *BDNewScroll(UIViewController *vc) {
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 0, vc.view.bounds.size.width,
                                                                          vc.view.bounds.size.height)];
    scroll.showsVerticalScrollIndicator = YES;
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 全屏铺在 view 上（MMUIViewController 的 view 延伸到导航栏底下），
    // 用系统自动内容内边距代替手写 safeArea 约束——约束在 viewWillAppear 激活
    // 有 NSISEngine 异常崩溃案例（0.4.0 真机复现），frame 方案无此问题
    if (@available(iOS 11.0, *)) {
        scroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    }
    [vc.view addSubview:scroll];
    return scroll;
}

// 子页导航头（返回 + 标题），返回 y 增量
static CGFloat BDNavHeader(UIViewController *vc, UIScrollView *scroll, NSString *title) {
    CGFloat w = vc.view.bounds.size.width;

    UIControl *back = [[UIControl alloc] initWithFrame:CGRectMake(4, 0, 60, 44)];
    UILabel *chev = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, 24, 44)];
    chev.text = @"‹";
    chev.font = [UIFont boldSystemFontOfSize:26];
    chev.textColor = BDTint();
    chev.textAlignment = NSTextAlignmentCenter;
    [back addSubview:chev];
    objc_setAssociatedObject(back, "view", vc, OBJC_ASSOCIATION_ASSIGN);
    [back addTarget:vc action:NSSelectorFromString(@"bdBackTap:")
   forControlEvents:UIControlEventTouchUpInside];
    [scroll addSubview:back];

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(64, 0, w - 80, 44)];
    lb.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    lb.text = title;
    [scroll addSubview:lb];
    return 52;
}

// 空状态提示卡
static CGFloat BDEmptyHint(UIViewController *vc, UIScrollView *scroll, CGFloat y, NSString *text) {
    CGFloat w = vc.view.bounds.size.width;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 84)];
    card.backgroundColor = BDCardBg();
    card.layer.cornerRadius = 15;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [BDSecondaryText() colorWithAlphaComponent:0.25].CGColor;
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 62, 84)];
    lb.font = [UIFont systemFontOfSize:13];
    lb.textColor = BDSecondaryText();
    lb.textAlignment = NSTextAlignmentCenter;
    lb.numberOfLines = 0;
    lb.text = text;
    [card addSubview:lb];
    [scroll addSubview:card];
    return y + 84 + 12;
}

// 页脚
static CGFloat BDFooter(UIViewController *vc, UIScrollView *scroll, CGFloat y) {
    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(0, y + 4, vc.view.bounds.size.width, 20)];
    foot.font = [UIFont systemFontOfSize:12];
    foot.textColor = BDSecondaryText();
    foot.textAlignment = NSTextAlignmentCenter;
    foot.text = @"BubbleDeck · 本地气泡引擎";
    [scroll addSubview:foot];
    return y + 32;
}

// 通用行卡（左标题 + 右侧控件区已由调用方布置；高度 46，点按手势由调用方挂）
static UIView *BDRowCard(UIViewController *vc, UIScrollView *scroll, CGFloat y,
                         NSString *title, SEL tapSel) {
    CGFloat w = vc.view.bounds.size.width;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 46)];
    card.backgroundColor = BDCardBg();
    card.layer.cornerRadius = 15;

    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, w - 100, 46)];
    lb.font = [UIFont systemFontOfSize:15];
    lb.text = title;
    [card addSubview:lb];

    UILabel *chev = [[UILabel alloc] initWithFrame:CGRectMake(w - 60, 0, 30, 46)];
    chev.text = @"›";
    chev.font = [UIFont systemFontOfSize:20];
    chev.textColor = BDSecondaryText();
    chev.textAlignment = NSTextAlignmentCenter;
    [card addSubview:chev];

    if (tapSel) {
        UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc] initWithTarget:vc action:tapSel];
        [card addGestureRecognizer:gr];
    }
    [scroll addSubview:card];
    return card;
}

// ────── 主页 ──────

static void BDBuildMainPage(UIViewController *vc) {
    CGFloat w = vc.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(vc);
    if (!s_dlButtons) s_dlButtons = [NSMutableDictionary dictionary];
    [s_dlButtons removeAllObjects];

    CGFloat wIn = w - 30;
    CGFloat y = 8;

    // ── 头部：图标 + 名称 + 版本 + 状态胶囊 ──
    {
        CGFloat logoSize = 56;
        UIView *logo = [[UIView alloc] initWithFrame:CGRectMake((w - logoSize) / 2, y, logoSize, logoSize)];
        logo.backgroundColor = BDTint();
        logo.layer.cornerRadius = 14;
        UILabel *bl = [[UILabel alloc] initWithFrame:logo.bounds];
        bl.text = @"B";
        bl.font = [UIFont boldSystemFontOfSize:30];
        bl.textColor = [UIColor whiteColor];
        bl.textAlignment = NSTextAlignmentCenter;
        [logo addSubview:bl];
        [scroll addSubview:logo];
        y += logoSize + 8;

        UILabel *name = [[UILabel alloc] initWithFrame:CGRectMake(0, y, w, 30)];
        name.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
        name.textAlignment = NSTextAlignmentCenter;
        name.text = @"BubbleDeck";
        [scroll addSubview:name];
        y += 32;

        UILabel *ver = [[UILabel alloc] initWithFrame:CGRectMake(0, y, w, 18)];
        ver.font = [UIFont systemFontOfSize:13];
        ver.textColor = BDSecondaryText();
        ver.textAlignment = NSTextAlignmentCenter;
        ver.text = [NSString stringWithFormat:@"v%@", kTDVersion];
        [scroll addSubview:ver];
        y += 24;

        NSString *pillText;
        BOOL pillActive = NO;
        if (![TDConfig pluginEnabled]) {
            pillText = @"插件已停用";
        } else if ([TDConfig activePack]) {
            pillText = [NSString stringWithFormat:@"使用中：%@", [TDConfig activePack]];
            pillActive = YES;
        } else {
            pillText = @"未选择气泡";
        }
        CGFloat pillW = [pillText sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}].width + 24;
        UILabel *pill = [[UILabel alloc] initWithFrame:CGRectMake((w - pillW) / 2, y, pillW, 24)];
        pill.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
        pill.textAlignment = NSTextAlignmentCenter;
        pill.text = pillText;
        pill.layer.cornerRadius = 12;
        pill.clipsToBounds = YES;
        pill.textColor = pillActive ? [UIColor whiteColor] : BDSecondaryText();
        pill.backgroundColor = pillActive ? BDTint() : BDPlaceholderBg();
        [scroll addSubview:pill];
        y += 36;
    }

    // ── 启用插件卡：总开关 + 三入口 ──
    {
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 128)];
        card.backgroundColor = BDCardBg();
        card.layer.cornerRadius = 15;

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, wIn - 100, 48)];
        lb.font = [UIFont systemFontOfSize:15];
        lb.text = @"启用插件";
        [card addSubview:lb];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(wIn - 66, 8, 51, 31)];
        sw.on = [TDConfig pluginEnabled];
        [sw addTarget:vc action:NSSelectorFromString(@"bdEnableSwitch:")
         forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(sw, "view", vc, OBJC_ASSOCIATION_ASSIGN);
        [card addSubview:sw];

        // 三入口：下载气泡 / 更换气泡 / 设置中心
        NSArray *titles = @[@"下载气泡", @"更换气泡", @"设置中心"];
        NSArray *symbols = @[@"arrow.down.circle", @"paintbrush", @"gear"];
        CGFloat btnW = (wIn - 32 - 16) / 3;
        for (NSInteger i = 0; i < 3; i++) {
            UIControl *btn = [[UIControl alloc] initWithFrame:CGRectMake(16 + i * (btnW + 8), 54, btnW, 62)];
            btn.backgroundColor = BDPlaceholderBg();
            btn.layer.cornerRadius = 12;

            CGFloat iy = 8;
            if (@available(iOS 13.0, *)) {
                UIImage *img = [UIImage systemImageNamed:symbols[i]];
                if (img) {
                    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
                    iv.frame = CGRectMake((btnW - 24) / 2, iy, 24, 24);
                    iv.tintColor = [UIColor labelColor];
                    [btn addSubview:iv];
                }
                iy += 28;
            } else {
                iy += 12;
            }
            UILabel *tl = [[UILabel alloc] initWithFrame:CGRectMake(0, iy, btnW, 18)];
            tl.font = [UIFont systemFontOfSize:12];
            tl.textAlignment = NSTextAlignmentCenter;
            tl.text = titles[i];
            [btn addSubview:tl];

            objc_setAssociatedObject(btn, "page", @(i + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [btn addTarget:vc action:NSSelectorFromString(@"bdIconTap:")
          forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:btn];
        }
        [scroll addSubview:card];
        y += 128 + 12;
    }

    // ── 兑换激活码行 ──
    BDRowCard(vc, scroll, y, @"兑换激活码", NSSelectorFromString(@"bdRedeemTap:"));
    y += 46 + 12;

    y = BDFooter(vc, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 商店页（只列 owned） ──────

static void BDBuildStorePage(UIViewController *vc) {
    CGFloat w = vc.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(vc);
    if (!s_dlButtons) s_dlButtons = [NSMutableDictionary dictionary];
    [s_dlButtons removeAllObjects];

    CGFloat wIn = w - 30;
    CGFloat y = BDNavHeader(vc, scroll, @"在线气泡包");

    NSArray<NSString *> *packs = [TDConfig availablePacks];
    NSSet<NSString *> *installed = [NSSet setWithArray:packs];
    NSArray<NSDictionary *> *ents = [TDLicense entitlements];

    // 首次进页拉清单（成功/失败回调重建本页）
    if (!ents && !s_triedFetch && !s_fetchingEnts) {
        s_triedFetch = YES;
        BDFetchEntitlements(vc);
    }

    if (!ents) {
        NSString *hint = s_fetchingEnts ? @"正在获取在线包列表…"
                                        : @"连接服务器失败，请稍后重试";
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(15, y + 8, wIn, 24)];
        lb.font = [UIFont systemFontOfSize:13];
        lb.textColor = BDSecondaryText();
        lb.textAlignment = NSTextAlignmentCenter;
        lb.text = hint;
        [scroll addSubview:lb];
        y += 32;
    } else {
        // 只显示 owned（未拥有/已失效一律不出现）
        NSMutableArray<NSDictionary *> *owned = [NSMutableArray array];
        for (NSDictionary *p in ents) {
            if ([p isKindOfClass:[NSDictionary class]] && [p[@"owned"] boolValue]) [owned addObject:p];
        }

        if (owned.count == 0) {
            y = BDEmptyHint(vc, scroll, y,
                            @"还没有可用的气泡包\n回主页「兑换激活码」入账后出现在这里");
        } else {
            BOOL highlighted = NO;
            for (NSDictionary *p in owned) {
                NSString *name = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"";
                if (!name.length) continue;
                BOOL has = [installed containsObject:name];
                BOOL busy = [s_downloading isEqualToString:name];
                // 引导高亮：第一个 owned 且未安装的包（下一步动作）
                BOOL firstTodo = !has && !busy && !highlighted && !s_downloading;

                UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 64)];
                card.backgroundColor = BDCardBg();
                card.layer.cornerRadius = 15;
                if (@available(iOS 13.0, *)) {
                    card.layer.cornerCurve = kCACornerCurveContinuous;
                    if (firstTodo) {
                        card.layer.borderWidth = 1.5;
                        card.layer.borderColor = BDTint().CGColor;
                    }
                }

                UILabel *nm = [[UILabel alloc] initWithFrame:CGRectMake(16, 11, wIn - 160, 20)];
                nm.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
                nm.text = name;
                [card addSubview:nm];

                UILabel *sb = [[UILabel alloc] initWithFrame:CGRectMake(16, 34, wIn - 160, 16)];
                sb.font = [UIFont systemFontOfSize:12];
                sb.textColor = BDSecondaryText();
                sb.text = [NSString stringWithFormat:@"v%@ · %@",
                           p[@"version"] ?: @"1.0", BDFileSize([p[@"size"] longLongValue])];
                [card addSubview:sb];

                UIButton *dl = [UIButton buttonWithType:UIButtonTypeSystem];
                dl.frame = CGRectMake(wIn - 102, 16, 86, 32);
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
                    dl.backgroundColor = BDTint();
                    dl.tintColor = [UIColor whiteColor];
                    objc_setAssociatedObject(dl, "pack", name, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    [dl addTarget:vc action:NSSelectorFromString(@"bdDownloadTap:")
                   forControlEvents:UIControlEventTouchUpInside];
                    s_dlButtons[name] = dl;
                }
                [card addSubview:dl];
                [scroll addSubview:card];
                y += 64 + 12;
                if (firstTodo) highlighted = YES;
            }
        }
    }

    y = BDFooter(vc, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 主题页（只列已下载且授权有效） ──────

static void BDBuildThemePage(UIViewController *vc) {
    CGFloat w = vc.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(vc);
    if (!s_dlButtons) s_dlButtons = [NSMutableDictionary dictionary];
    [s_dlButtons removeAllObjects];

    CGFloat wIn = w - 30;
    CGFloat y = BDNavHeader(vc, scroll, @"选择气泡");

    NSString *active = [TDConfig activePack];
    NSArray<NSString *> *packs = [TDConfig availablePacks];
    // 激活名在包列表里不存在 = 配置残留，按未激活处理并清理
    if (active && ![packs containsObject:active]) {
        TDLog(@"DEV", @"[activePack] 指向不存在的包 %@，清理", active);
        [TDConfig setActivePack:nil];
        active = nil;
    }

    // 微信默认卡
    UIView *card = BDMakeCard(y, w, nil, @"微信默认",
                              @"不使用任何气泡包，恢复微信原生气泡",
                              nil, active == nil);
    UITapGestureRecognizer *dgr = [[UITapGestureRecognizer alloc]
        initWithTarget:vc action:NSSelectorFromString(@"bdCardTap:")];
    [card addGestureRecognizer:dgr];
    [scroll addSubview:card];
    y += 76 + 12;

    // 只显示已下载且授权有效的包：在线来源但闸门关闭（封卡/换号/离线超期）的包不出现
    BOOL anyShown = NO;
    for (NSString *name in packs) {
        if ([[TDConfig sourceForPack:name] isEqualToString:@"online"]
            && ![TDLicense gateOpenForPack:name]) continue;

        NSString *dir = [TDPackLoader packDirForName:name];
        NSString *subtitle = [NSString stringWithFormat:@"%ld 图",
                              dir ? (long)BDPackImageCount(dir) : 0L];
        UIImage *thumb = dir
            ? [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"icon.png"]]
            : nil;

        UIView *c = BDMakeCard(y, w, name, name, subtitle, thumb, [active isEqualToString:name]);
        UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc]
            initWithTarget:vc action:NSSelectorFromString(@"bdCardTap:")];
        [c addGestureRecognizer:gr];
        [scroll addSubview:c];
        y += 76 + 12;
        anyShown = YES;
    }

    if (!anyShown) {
        y = BDEmptyHint(vc, scroll, y,
                        @"还没有已下载的气泡包\n先回主页「下载气泡」获取");
    }

    y = BDFooter(vc, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 设置页 ──────

static void BDBuildSettingsPage(UIViewController *vc) {
    CGFloat w = vc.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(vc);
    if (!s_dlButtons) s_dlButtons = [NSMutableDictionary dictionary];
    [s_dlButtons removeAllObjects];

    CGFloat wIn = w - 30;
    CGFloat y = BDNavHeader(vc, scroll, @"设置中心");

    // 日志开关卡
    {
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 46)];
        card.backgroundColor = BDCardBg();
        card.layer.cornerRadius = 15;

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, wIn - 100, 46)];
        lb.font = [UIFont systemFontOfSize:15];
        lb.text = @"日志记录";
        [card addSubview:lb];

        UISwitch *logSw = [[UISwitch alloc] initWithFrame:CGRectMake(wIn - 66, 8, 51, 31)];
        logSw.on = [_TDLogManager fileLoggingEnabled];
        [logSw addTarget:vc action:NSSelectorFromString(@"bdLogSwitch:")
         forControlEvents:UIControlEventValueChanged];
        objc_setAssociatedObject(logSw, "view", vc, OBJC_ASSOCIATION_ASSIGN);
        [card addSubview:logSw];
        [scroll addSubview:card];
        y += 46 + 12;
    }

    // 重新加载行
    BDRowCard(vc, scroll, y, @"重新加载气泡包", NSSelectorFromString(@"bdReloadTap:"));
    y += 46 + 12;

    // 关于卡
    {
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 64)];
        card.backgroundColor = BDCardBg();
        card.layer.cornerRadius = 15;

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 11, wIn - 32, 20)];
        lb.font = [UIFont systemFontOfSize:15];
        lb.text = [NSString stringWithFormat:@"BubbleDeck v%@", kTDVersion];
        [card addSubview:lb];

        UILabel *sb = [[UILabel alloc] initWithFrame:CGRectMake(16, 34, wIn - 32, 16)];
        sb.font = [UIFont systemFontOfSize:12];
        sb.textColor = BDSecondaryText();
        sb.text = [NSString stringWithFormat:@"设备尾号 %@", [TDLicense deviceTail]];
        [card addSubview:sb];
        [scroll addSubview:card];
        y += 64 + 12;
    }

    y = BDFooter(vc, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 页面分发 ──────

static void BDBuildPage(UIViewController *vc) {
    // 移除旧 UI（重建）
    for (UIView *sub in vc.view.subviews) [sub removeFromSuperview];

    switch (s_page) {
        case 1:  BDBuildStorePage(vc);    break;
        case 2:  BDBuildThemePage(vc);    break;
        case 3:  BDBuildSettingsPage(vc); break;
        default: BDBuildMainPage(vc);     break;
    }
}

// ────── 交互处理（注册在类对上的实例方法） ──────

// 总开关
static void bdEnableSwitch(id self, SEL _cmd, UISwitch *sw) {
    UIViewController *vc = (UIViewController *)self;
    [TDConfig setPluginEnabled:sw.on];
    TDLog(@"DEV", @"[Plugin] 总开关 %@", sw.on ? @"开" : @"关");
    BDBuildPage(vc);
}

// 主页三入口
static void bdIconTap(id self, SEL _cmd, UIControl *btn) {
    NSNumber *page = objc_getAssociatedObject(btn, "page");
    s_page = page.integerValue;
    BDBuildPage((UIViewController *)self);
}

// 子页返回
static void bdBackTap(id self, SEL _cmd, UIControl *btn) {
    s_page = 0;
    BDBuildPage((UIViewController *)self);
}

// 主题页卡片：启用 / 恢复默认
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

    // 安全网：主题页理论上只显示闸门放行的包，这里再拦一次（授权可能在页面停留期间失效）
    if ([[TDConfig sourceForPack:pack] isEqualToString:@"online"]
        && ![TDLicense gateOpenForPack:pack]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"授权不可用"
            message:[NSString stringWithFormat:@"「%@」当前无有效授权，请联网后重试或重新购买激活码。", pack]
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }

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

// 设置页：重新加载
static void bdReloadTap(id self, SEL _cmd, UIButton *btn) {
    UIViewController *vc = (UIViewController *)self;
    [TDBubbleEngine purgeCaches];       // 清负缓存，包内容变更即时生效
    s_triedFetch = NO;                  // 在线清单允许重试
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已重新加载"
        message:[NSString stringWithFormat:@"当前 %lu 个气泡包可用。",
                 (unsigned long)[TDConfig availablePacks].count]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
    TDLog(@"DEV", @"[Pack] 重新加载，packs=%@", [TDConfig availablePacks]);
}

// 设置页：日志开关
static void bdLogSwitch(id self, SEL _cmd, UISwitch *sw) {
    [_TDLogManager setFileLoggingEnabled:sw.on];
    TDLog(@"DEV", @"[Log] 文件日志 %@", sw.on ? @"开" : @"关");
}

// 主页：兑换激活码（激活唯一入口）→ 成功自动跳商店页
static void bdRedeemTap(id self, SEL _cmd, UIControl *btn) {
    UIViewController *vc = (UIViewController *)self;

    // 绑定主键就是 wxid：抓不到（未登录/早期）直接本地拦，不给发请求
    if (![TDLicense currentWxid]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"无法激活"
            message:@"请先登录微信后再激活（激活码会绑定当前微信号）"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"兑换激活码"
        message:@"输入气泡包激活码。激活后绑定当前微信号，永久有效，不可换绑。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"XXXX-XXXX-XXXX-XXXX";
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    __weak UIViewController *wv = vc;
    [alert addAction:[UIAlertAction actionWithTitle:@"激活" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) {
        NSString *code = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!code.length) return;
        TDLog(@"LIC", @"[Activate] 提交激活码（尾 4 位: %@）",
              code.length >= 4 ? [code substringFromIndex:code.length - 4] : code);
        [TDLicense activateLicense:code completion:^(BOOL ok, NSString *message) {
            UIViewController *v = wv;
            UIAlertController *done = [UIAlertController alertControllerWithTitle:
                ok ? @"激活成功" : @"激活失败"
                message:message
                preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *x) {
                if (!ok) return;
                UIViewController *v2 = wv;
                if (v2 && v2.isViewLoaded) {
                    s_page = 1;          // 跳商店页：新入账的包带着 [下载] 按钮等着
                    BDBuildPage(v2);     // activate 内部已同步报到，重建即见
                }
            }]];
            [v presentViewController:done animated:YES completion:nil];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:alert animated:YES completion:nil];
}

// 商店页：下载（url/md5/key 直接取自缓存清单 owned 包）
static void BDStartDownload(UIViewController *vc, NSString *name) {
    if (s_downloading || !name.length) return;
    NSDictionary *pack = nil;
    for (NSDictionary *p in [TDLicense entitlements]) {
        if ([p isKindOfClass:[NSDictionary class]] && [name isEqualToString:p[@"name"]]) {
            pack = p;
            break;
        }
    }
    // 无授权不下发（闸门同源判断）
    if (![pack[@"owned"] boolValue]) return;
    NSString *url = [pack[@"url"] isKindOfClass:[NSString class]] ? pack[@"url"] : @"";
    NSString *key = [pack[@"key"] isKindOfClass:[NSString class]] ? pack[@"key"] : @"";
    if (!url.length || !key.length) return;

    s_downloading = name;
    s_dlKey = key;
    s_dlProgress = 0;
    UIButton *b = s_dlButtons[name];
    if (b) { b.enabled = NO; [b setTitle:@"0%" forState:UIControlStateNormal]; }
    TDLog(@"LIC", @"[Download] 开始: %@", name);

    __weak UIViewController *wv = vc;
    [[BDDownloader shared] fetchPack:name url:url
                                 md5:[pack[@"md5"] isKindOfClass:[NSString class]] ? pack[@"md5"] : @""
                          completion:^(BOOL ok, NSString *message) {
        s_downloading = nil;
        UIViewController *v = wv;
        if (v && v.isViewLoaded) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:
                ok ? @"下载完成" : @"下载失败"
                message:ok ? [NSString stringWithFormat:@"「%@」已安装，去「更换气泡」启用。", name]
                           : message
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *x) {
                UIViewController *v2 = wv;
                if (ok && v2 && v2.isViewLoaded) {
                    s_page = 2;         // 跳主题页启用
                    BDBuildPage(v2);
                }
            }]];
            [v presentViewController:a animated:YES completion:nil];
            BDBuildPage(v);   // 先重建（下载行回「已安装」），再弹窗
        }
    }];
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

        // 授权启动报到（后台异步：POST /packs → 缓存 owned 清单 → 闸门状态就位）
        [TDLicense refreshEntitlements];

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
            class_addMethod(entryClass, NSSelectorFromString(@"bdEnableSwitch:"), (IMP)bdEnableSwitch, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdIconTap:"), (IMP)bdIconTap, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdBackTap:"), (IMP)bdBackTap, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdCardTap:"), (IMP)bdCardTap, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdReloadTap:"), (IMP)bdReloadTap, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdLogSwitch:"), (IMP)bdLogSwitch, "v@:@");
            class_addMethod(entryClass, NSSelectorFromString(@"bdRedeemTap:"), (IMP)bdRedeemTap, "v@:@");
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
