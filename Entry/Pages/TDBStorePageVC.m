//
//  TDBStorePageVC.m
//  BubbleDeck
//
//  商店页（逻辑自 v0.4.x TDBubbleEntry.m 平移，业务不变）：
//  只列 owned 包（未拥有、已失效一律不出现），三态按钮：下载 → 进度 → 已安装。
//  下载状态/进度/清单拉取状态归本页私有 static；下载完成 push 主题页启用。
//

#import "TDBPages.h"
#import "../TDBUI.h"
#import "../../Core/TDLog.h"
#import "../../Core/TDConfig.h"
#import "../../Core/TDLicense.h"
#import "../../Engine/TDZip.h"
#import "../../Engine/TDContainer.h"
#import <objc/runtime.h>

// ────── 下载状态（本页私有） ──────

static NSString *s_downloading = nil;                 // 正在下载的包名
static NSString *s_dlKey = nil;                       // 当前下载任务的 .bdpack 密钥（清单下发）
static NSString *s_dlVersion = nil;                   // 当前下载任务的容器版本（GCM AAD 用）
static float s_dlProgress = 0;
static NSMutableDictionary<NSString *, UIButton *> *s_dlButtons;
static BOOL s_fetchingEnts = NO;                      // 报到进行中
static BOOL s_triedFetch = NO;                        // 本次会话是否已尝试报到（防重建循环）

// 进度写回当前下载按钮（页面重建后按钮会被 s_dlButtons 换新）
static void BDUpdateProgressButton(void) {
    UIButton *b = s_dlButtons[s_downloading];
    if (b) {
        b.enabled = NO;
        [b setTitle:[NSString stringWithFormat:@"%.0f%%", s_dlProgress * 100]
           forState:UIControlStateNormal];
    }
}

// ────── .bdpack 下载器：进度 → md5 校验 → 试解密 → 密文落盘（零解压）。同一时刻只跑一个任务。 ──────

@interface BDDownloader : NSObject <NSURLSessionDownloadDelegate>
+ (instancetype)shared;
- (void)fetchPack:(NSString *)name url:(NSString *)url md5:(NSString *)md5
          version:(NSString *)version
       completion:(void (^)(BOOL ok, NSString *message))cb;   // 主线程回调
@end

@implementation BDDownloader {
    NSURLSession *_session;
    void (^_cb)(BOOL, NSString *);
    NSString *_name, *_md5, *_version;
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
          version:(NSString *)version
       completion:(void (^)(BOOL, NSString *))cb {
    _cb = cb;
    _name = name;
    _md5 = md5.lowercaseString;
    _version = version;
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
    // V3 零解压安装：试解密校验（错 key/篡改在此报人话）→ 密文落盘 pack.bdpack + info.json
    else if (![TDContainer installBdpackData:data key:s_dlKey packName:_name
                                     version:_version error:&zipErr])
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

// ────── 页面 ──────

@implementation TDBStorePageVC

+ (void)resetFetchState {
    s_triedFetch = NO;
}

- (void)viewDidLoad {
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL))method_getImplementation(m))(self, _cmd);
    self.title = @"下载气泡";
}

- (void)viewWillAppear:(BOOL)animated {
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);

    self.view.backgroundColor = BDPageBg();
    if (self.view.bounds.size.width < 1) return;
    [self buildPage];
}

// 首次进页拉清单（成功/失败回调重建本页）
- (void)fetchEntitlements {
    s_fetchingEnts = YES;
    __weak typeof(self) wv = self;
    [TDLicense refreshEntitlementsWithCompletion:^(BOOL ok) {
        s_fetchingEnts = NO;
        __strong typeof(wv) v = wv;
        if (v && v.isViewLoaded) [v buildPage];
    }];
}

- (void)buildPage {
    for (UIView *sub in self.view.subviews) [sub removeFromSuperview];

    if (!s_dlButtons) s_dlButtons = [NSMutableDictionary dictionary];
    [s_dlButtons removeAllObjects];

    CGFloat w = self.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(self);

    CGFloat wIn = w - 30;
    CGFloat y = 16;

    NSArray<NSString *> *packs = [TDConfig availablePacks];
    NSSet<NSString *> *installed = [NSSet setWithArray:packs];
    NSArray<NSDictionary *> *ents = [TDLicense entitlements];

    // 首次进页拉清单（成功/失败回调重建本页）
    if (!ents && !s_triedFetch && !s_fetchingEnts) {
        s_triedFetch = YES;
        [self fetchEntitlements];
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
            y = BDEmptyHint(self, scroll, y,
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
                sb.font = [UIFont systemFontOfSize:13];
                sb.textColor = BDSecondaryText();
                sb.text = [NSString stringWithFormat:@"v%@ · %@",
                           p[@"version"] ?: @"1.0", BDFileSize([p[@"size"] longLongValue])];
                [card addSubview:sb];

                UIButton *dl = [UIButton buttonWithType:UIButtonTypeSystem];
                dl.frame = CGRectMake(wIn - 102, 16, 86, 32);
                dl.layer.cornerRadius = 11;
                if (@available(iOS 13.0, *)) dl.layer.cornerCurve = kCACornerCurveContinuous;
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
                    [dl addTarget:self action:@selector(bdDownloadTap:)
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

    y = BDFooter(self, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 交互 ──────

// 下载（url/md5/key 直接取自缓存清单 owned 包）
- (void)startDownload:(NSString *)name {
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
    s_dlVersion = [pack[@"version"] isKindOfClass:[NSString class]] ? pack[@"version"] : @"1.0";
    s_dlProgress = 0;
    UIButton *b = s_dlButtons[name];
    if (b) { b.enabled = NO; [b setTitle:@"0%" forState:UIControlStateNormal]; }
    TDLog(@"LIC", @"[Download] 开始: %@", name);

    __weak typeof(self) wv = self;
    [[BDDownloader shared] fetchPack:name url:url
                                 md5:[pack[@"md5"] isKindOfClass:[NSString class]] ? pack[@"md5"] : @""
                             version:s_dlVersion
                          completion:^(BOOL ok, NSString *message) {
        s_downloading = nil;
        __strong typeof(wv) v = wv;
        if (v && v.isViewLoaded) {
            [v buildPage];   // 先重建（下载行回「已安装」），再弹窗
            UIAlertController *a = [UIAlertController alertControllerWithTitle:
                ok ? @"下载完成" : @"下载失败"
                message:ok ? [NSString stringWithFormat:@"「%@」已安装，去「更换气泡」启用。", name]
                           : message
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *x) {
                __strong typeof(wv) v2 = wv;
                if (ok && v2 && v2.isViewLoaded) {
                    // push 主题页启用
                    [v2.navigationController pushViewController:[[TDBThemePageVC alloc] init]
                                                       animated:YES];
                }
            }]];
            [v presentViewController:a animated:YES completion:nil];
        }
    }];
}

- (void)bdDownloadTap:(UIButton *)btn {
    NSString *name = objc_getAssociatedObject(btn, "pack");
    [self startDownload:name];
}

@end
