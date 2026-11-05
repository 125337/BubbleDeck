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
                              nil, active == nil, nil);
    UITapGestureRecognizer *dgr = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:NSSelectorFromString(@"bdCardTap:")];
    [card addGestureRecognizer:dgr];
    [scroll addSubview:card];
    y += 76 + 12;

    // 本地已装的在线包全部显示，按授权状态标灰（封禁/未授权/待验证），点击时拦截
    BOOL anyShown = NO;
    for (NSString *name in packs) {
        NSString *badge = nil;
        if ([[TDConfig sourceForPack:name] isEqualToString:@"online"]) {
            if ([TDLicense entitlementsExpired])      badge = @"待验证";
            else if ([TDLicense isRevokedPack:name])  badge = @"已封禁";
            else if (![TDLicense isOwnedPack:name])   badge = @"未授权";
        }

        NSString *dir = [TDPackLoader packDirForName:name];
        UIImage *thumb = nil;
        // 分流：盘上常密包（V3）icon 走容器索引；明文目录包走原逻辑
        if (dir && [[NSFileManager defaultManager]
                    fileExistsAtPath:[dir stringByAppendingPathComponent:@"pack.bdpack"]]) {
            NSError *err = nil;
            TDContainer *c = [TDContainer cachedContainerForPack:name error:&err];
            if (c) {
                thumb = [UIImage imageWithData:[c dataForEntry:@"icon.png"]];
            } else {
                TDLog(@"DEV", @"[主题页] 容器打开失败: %@ - %@", name, err.localizedDescription);
            }
        } else {
            thumb = dir
                ? [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"icon.png"]]
                : nil;
        }
        // 副标题 = 作者名（info.json 安装时明文落盘，无需 key/容器/网络；
        // 封禁、待验证、未授权卡均正常显示）。无 author 兜底「未知作者」。
        NSString *author = nil;
        if (dir) {
            NSData *infoData = [NSData dataWithContentsOfFile:
                                [dir stringByAppendingPathComponent:@"info.json"]];
            id obj = infoData ? [NSJSONSerialization JSONObjectWithData:infoData options:0 error:nil] : nil;
            id a = [obj isKindOfClass:[NSDictionary class]] ? obj[@"author"] : nil;
            if ([a isKindOfClass:[NSString class]] && [(NSString *)a length]) author = a;
        }
        NSString *subtitle = author ?: @"未知作者";

        // 左滑删除容器：删除按钮垫底，卡片盖上可横向拖动（微信默认卡不可删）
        UIView *row = [[UIView alloc] initWithFrame:CGRectMake(0, y, w, 76)];

        UIButton *del = [UIButton buttonWithType:UIButtonTypeSystem];
        del.frame = CGRectMake(w - 15 - 84, 0, 84, 76);
        del.backgroundColor = [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
        del.layer.cornerRadius = 15;
        [del setTitle:@"删除" forState:UIControlStateNormal];
        [del setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        del.titleLabel.font = [UIFont systemFontOfSize:15];
        objc_setAssociatedObject(del, "pack", name, OBJC_ASSOCIATION_COPY);
        [del addTarget:self action:@selector(bdDeleteTap:) forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:del];

        UIView *c = BDMakeCard(0, w, name, name, subtitle, thumb,
                               [active isEqualToString:name], badge);
        c.tag = 1001;
        UITapGestureRecognizer *gr = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:NSSelectorFromString(@"bdCardTap:")];
        [c addGestureRecognizer:gr];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(bdCardPan:)];
        pan.delegate = self;
        [c addGestureRecognizer:pan];
        [row addSubview:c];
        [scroll addSubview:row];
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

    // 安全网：主题页会显示标灰的不可用包，这里按状态拦截（授权可能在页面停留期间变化）
    if ([[TDConfig sourceForPack:pack] isEqualToString:@"online"]
        && ![TDLicense gateOpenForPack:pack]) {
        if ([TDLicense entitlementsExpired]) {
            BDShowAlert(self, @"暂时无法验证",
                        [NSString stringWithFormat:@"「%@」需要联网验证授权后才能使用，请检查网络后重进本页。", pack],
                        @"好");
        } else if ([TDLicense isRevokedPack:pack]) {
            BDShowAlert(self, @"已被封禁",
                        [NSString stringWithFormat:@"「%@」的激活码已被封禁，如有疑问请联系卖家。", pack],
                        @"好");
        } else {
            BDShowAlert(self, @"未授权",
                        [NSString stringWithFormat:@"当前微信号没有「%@」的授权，请激活对应激活码后使用。", pack],
                        @"好");
        }
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

// ────── 左滑删除 ──────

static const CGFloat BDDelOpenX = -84.0;   // 删除按钮宽度

// 只让横向意图的拖动接管（竖直方向放行给滚动）
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    if ([gr isKindOfClass:[UIPanGestureRecognizer class]] && gr.view.tag == 1001) {
        CGPoint v = [(UIPanGestureRecognizer *)gr velocityInView:gr.view];
        return fabs(v.x) > fabs(v.y);
    }
    return YES;
}

- (void)bdCardPan:(UIPanGestureRecognizer *)gr {
    UIView *card = gr.view;
    UIScrollView *scroll = (UIScrollView *)card.superview.superview;

    if (gr.state == UIGestureRecognizerStateBegan) {
        scroll.panGestureRecognizer.enabled = NO;   // 横向拖动期间锁滚动，结束恢复
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGFloat x = card.transform.tx + [gr translationInView:card.superview].x;
        [gr setTranslation:CGPointZero inView:card.superview];
        if (x > 0) x /= 3;                                        // 右滑橡皮筋
        if (x < BDDelOpenX) x = BDDelOpenX + (x - BDDelOpenX) / 3; // 露头后橡皮筋
        card.transform = CGAffineTransformMakeTranslation(x, 0);
    } else if (gr.state == UIGestureRecognizerStateEnded
               || gr.state == UIGestureRecognizerStateCancelled) {
        scroll.panGestureRecognizer.enabled = YES;
        BOOL open = card.transform.tx < BDDelOpenX / 2;
        [self bdSnapCard:card open:open];
        if (open) [self bdCloseSiblingsOf:card];
    }
}

// 卡片吸附动画
- (void)bdSnapCard:(UIView *)card open:(BOOL)open {
    [UIView animateWithDuration:0.2 animations:^{
        card.transform = open ? CGAffineTransformMakeTranslation(BDDelOpenX, 0)
                              : CGAffineTransformIdentity;
    }];
}

// 关掉其他已滑开的卡片
- (void)bdCloseSiblingsOf:(UIView *)card {
    for (UIView *row in card.superview.superview.subviews) {
        for (UIView *sub in row.subviews) {
            if (sub.tag == 1001 && sub != card && sub.transform.tx != 0) {
                [self bdSnapCard:sub open:NO];
            }
        }
    }
}

// 删除按钮
- (void)bdDeleteTap:(UIButton *)btn {
    NSString *pack = objc_getAssociatedObject(btn, "pack");
    if (!pack.length) return;
    BOOL isActive = [[TDConfig activePack] isEqualToString:pack];

    NSString *msg = isActive
        ? [NSString stringWithFormat:@"「%@」正在使用中，删除后将恢复微信默认气泡。", pack]
        : [NSString stringWithFormat:@"「%@」将从本机删除。\n服务器授权保留，以后可重新下载。", pack];
    BDShowConfirm(self, @"删除气泡包", msg, @"删除", YES, ^{
        NSString *dir = [TDPackLoader packDirForName:pack];
        if (dir) [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        [TDContainer purgeContainerForPack:pack];
        if (isActive) {
            [TDConfig setActivePack:nil];
            TDLog(@"DEV", @"[Pack] 删除正在使用的包，恢复微信默认: %@", pack);
        }
        TDLog(@"DEV", @"[Pack] 已删除气泡包: %@", pack);
        [self buildPage];
    });
}

@end
