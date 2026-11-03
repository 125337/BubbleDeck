//
//  TDBThemePageVC.m
//  BubbleDeck
//
//  主题页（逻辑自 v0.4.x TDBubbleEntry.m 平移，业务不变）：
//  只列已下载且授权有效的包（微信默认 + 本地包），点卡片启用。
//

#import "TDBPages.h"
#import "../TDBUI.h"
#import "../../Core/TDLog.h"
#import "../../Core/TDConfig.h"
#import "../../Core/TDLicense.h"
#import "../../Engine/TDPackLoader.h"
#import "../../Engine/TDContainer.h"
#import <objc/runtime.h>

@implementation TDBThemePageVC

- (void)viewDidLoad {
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL))method_getImplementation(m))(self, _cmd);
    self.title = @"更换气泡";
}

- (void)viewWillAppear:(BOOL)animated {
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);

    self.view.backgroundColor = BDPageBg();
    if (self.view.bounds.size.width < 1) return;
    [self buildPage];
}

// ────── 页面构建 ──────

- (void)buildPage {
    for (UIView *sub in self.view.subviews) [sub removeFromSuperview];

    CGFloat w = self.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(self);

    CGFloat y = 16;

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
        initWithTarget:self action:NSSelectorFromString(@"bdCardTap:")];
    [card addGestureRecognizer:dgr];
    [scroll addSubview:card];
    y += 76 + 12;

    // 只显示已下载且授权有效的包：在线来源但闸门关闭（封卡/换号/离线超期）的包不出现
    BOOL anyShown = NO;
    for (NSString *name in packs) {
        if ([[TDConfig sourceForPack:name] isEqualToString:@"online"]
            && ![TDLicense gateOpenForPack:name]) continue;

        NSString *dir = [TDPackLoader packDirForName:name];
        NSInteger imgCount = 0;
        UIImage *thumb = nil;
        // 分流：盘上常密包（V3）图片数/icon 走容器索引；明文目录包走原逻辑
        if (dir && [[NSFileManager defaultManager]
                    fileExistsAtPath:[dir stringByAppendingPathComponent:@"pack.bdpack"]]) {
            NSError *err = nil;
            TDContainer *c = [TDContainer cachedContainerForPack:name error:&err];
            if (c) {
                imgCount = [c imageCount];
                thumb = [UIImage imageWithData:[c dataForEntry:@"icon.png"]];
            } else {
                TDLog(@"DEV", @"[主题页] 容器打开失败: %@ - %@", name, err.localizedDescription);
            }
        } else {
            imgCount = dir ? BDPackImageCount(dir) : 0;
            thumb = dir
                ? [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"icon.png"]]
                : nil;
        }
        NSString *subtitle = [NSString stringWithFormat:@"%ld 图", (long)imgCount];

        UIView *c = BDMakeCard(y, w, name, name, subtitle, thumb, [active isEqualToString:name]);
        UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:NSSelectorFromString(@"bdCardTap:")];
        [c addGestureRecognizer:gr];
        [scroll addSubview:c];
        y += 76 + 12;
        anyShown = YES;
    }

    if (!anyShown) {
        y = BDEmptyHint(self, scroll, y,
                        @"还没有已下载的气泡包\n先回主页「下载气泡」获取");
    }

    y = BDFooter(self, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 交互 ──────

// 卡片：启用 / 恢复默认
- (void)bdCardTap:(UITapGestureRecognizer *)gr {
    NSString *pack = objc_getAssociatedObject(gr.view, "pack");
    NSString *active = [TDConfig activePack];

    if (pack == nil) {
        // 微信默认卡：仅在当前有激活气泡包时提供恢复
        if (!active) return;
        BDShowConfirm(self, @"恢复微信默认",
                      [NSString stringWithFormat:@"将停用「%@」，恢复微信原生气泡。", active],
                      @"恢复默认", YES, ^{
            [TDConfig setActivePack:nil];
            TDLog(@"DEV", @"[Pack] 恢复微信默认（原 %@）", active);
            [self buildPage];
        });
        return;
    }

    if ([pack isEqualToString:active]) return; // 已在使用，无操作

    // 安全网：主题页理论上只显示闸门放行的包，这里再拦一次（授权可能在页面停留期间失效）
    if ([[TDConfig sourceForPack:pack] isEqualToString:@"online"]
        && ![TDLicense gateOpenForPack:pack]) {
        BDShowAlert(self, @"授权不可用",
                    [NSString stringWithFormat:@"「%@」当前无有效授权，请联网后重试或重新购买激活码。", pack],
                    @"好");
        return;
    }

    BDShowConfirm(self, @"启用气泡包",
                  [NSString stringWithFormat:@"启用「%@」？\n新打开的聊天页生效。", pack],
                  @"启用", NO, ^{
        [TDConfig setActivePack:pack];
        TDLog(@"DEV", @"[Pack] 激活气泡包: %@", pack);
        [self buildPage];
    });
}

@end
