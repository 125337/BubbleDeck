//
//  TDBUI.m
//  BubbleDeck
//
//  插件页共享自绘组件库实现（逻辑自 v0.4.x TDBubbleEntry.m 平移，业务不变）。
//

#import "TDBUI.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

// ────── 配色 ──────

// 微信页面底色取样（Mio/WCR 同款：现场实例化微信 WCTableViewManager，
// 读它自建 tableView 的背景色——色值由微信主题体系写，深浅色跟随微信而非 iOS 系统）。
// 不缓存：微信主题运行时可切，每次现取。objc_msgSend 对 nil 全程安全。
UIColor *BDPageBg(void) {
    Class mgrCls = objc_getClass("WCTableViewManager");
    SEL ifs = NSSelectorFromString(@"initWithFrame:style:");
    id alloced = ((id (*)(id, SEL))objc_msgSend)((id)mgrCls, NSSelectorFromString(@"alloc"));
    id mgr = [mgrCls instancesRespondToSelector:ifs]
        ? ((id (*)(id, SEL, CGRect, long))objc_msgSend)(alloced, ifs, CGRectZero, (long)UITableViewStyleGrouped)
        : ((id (*)(id, SEL))objc_msgSend)(alloced, NSSelectorFromString(@"init"));
    SEL tvg = NSSelectorFromString(@"tableView");
    id tv = (mgr && [mgr respondsToSelector:tvg]) ? ((id (*)(id, SEL))objc_msgSend)(mgr, tvg) : nil;
    return [tv isKindOfClass:[UITableView class]]
        ? ((id (*)(id, SEL))objc_msgSend)(tv, NSSelectorFromString(@"backgroundColor"))
        : nil;
}

UIColor *BDCardBg(void) {
    if (@available(iOS 13.0, *)) return [UIColor secondarySystemGroupedBackgroundColor];
    return [UIColor whiteColor];
}

// 卡片内的次级按钮/胶囊底
UIColor *BDChipBg(void) {
    if (@available(iOS 13.0, *)) return [UIColor tertiarySystemFillColor];
    return [UIColor colorWithRed:0.937 green:0.937 blue:0.957 alpha:1.0];
}

UIColor *BDSecondaryText(void) {
    if (@available(iOS 13.0, *)) return [UIColor secondaryLabelColor];
    return [UIColor grayColor];
}

UIColor *BDTint(void) {
    if (@available(iOS 13.0, *)) return [UIColor systemBlueColor];
    return [UIColor colorWithRed:0.0 green:0.48 blue:1.0 alpha:1.0];
}

// ────── 分层液态玻璃 ──────
// 三级降级：iOS 26+ 运行时探测 UIGlassEffect（原生液态玻璃）→
// iOS 13–25 SystemUltraThinMaterial 磨砂 + 四向描边 → 失败一律回填不透明白卡，绝不 crash。

// iOS 26+ 原生液态玻璃：只走运行时探测（Theos SDK 版本不确定，不编译期引用）
static id BDNewGlassEffect(void) {
    Class cls = NSClassFromString(@"UIGlassEffect");
    if (!cls || ![cls isSubclassOfClass:[UIVisualEffect class]]) return nil;
    @try {
        id eff = [[cls alloc] init];
        return [eff isKindOfClass:[UIVisualEffect class]] ? eff : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

// iOS 13–25 磨砂
static id BDNewUltraThinEffect(void) {
    if (@available(iOS 13.0, *)) {
        @try {
            return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

// 单条描边渐变
static void BDAddEdgeStroke(UIView *host, CGRect frame, UIColor *c0, UIColor *c1,
                            CGPoint p0, CGPoint p1) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = frame;
    g.colors = [NSArray arrayWithObjects:(__bridge id)c0.CGColor, (__bridge id)c1.CGColor, nil];
    g.startPoint = p0;
    g.endPoint = p1;
    [host.layer addSublayer:g];
}

// 旧系统磨砂的四向描边：上缘白高光 1.5pt、下缘黑暗边 1.5pt、左右微光/微暗（纯明度）
static void BDAddEdgeStrokes(UIView *host) {
    CGFloat w = host.bounds.size.width, h = host.bounds.size.height;
    if (w < 1 || h < 1) return;
    BDAddEdgeStroke(host, CGRectMake(0, 0, w, 1.5),                        // 上缘：白高光向下淡出
                    [UIColor colorWithWhite:1 alpha:0.9], [UIColor colorWithWhite:1 alpha:0],
                    CGPointMake(0.5, 0), CGPointMake(0.5, 1));
    BDAddEdgeStroke(host, CGRectMake(0, h - 1.5, w, 1.5),                  // 下缘：黑暗边向上淡出
                    [UIColor colorWithWhite:0 alpha:0], [UIColor colorWithWhite:0 alpha:0.28],
                    CGPointMake(0.5, 0), CGPointMake(0.5, 1));
    BDAddEdgeStroke(host, CGRectMake(0, 0, 1, h),                          // 左侧：微光
                    [UIColor colorWithWhite:1 alpha:0.5], [UIColor colorWithWhite:1 alpha:0],
                    CGPointMake(0, 0.5), CGPointMake(1, 0.5));
    BDAddEdgeStroke(host, CGRectMake(w - 1, 0, 1, h),                      // 右侧：微暗
                    [UIColor colorWithWhite:0 alpha:0.2], [UIColor colorWithWhite:0 alpha:0],
                    CGPointMake(1, 0.5), CGPointMake(0, 0.5));
}

BOOL BDInstallGlassMaterial(UIView *host) {
    if (!host || host.bounds.size.width < 1) return NO;
    id effect = BDNewGlassEffect();                 // iOS 26+：原生液态玻璃
    BOOL native = (effect != nil);
    if (!effect) effect = BDNewUltraThinEffect();   // iOS 13–25：磨砂
    if (!effect) return NO;                         // 兜底：调用方回填白卡
    @try {
        UIVisualEffectView *mat = [[UIVisualEffectView alloc] initWithEffect:effect];
        mat.frame = host.bounds;
        mat.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        mat.userInteractionEnabled = NO;
        [host insertSubview:mat atIndex:0];
        if (!native) BDAddEdgeStrokes(host);        // 旧系统补描边（原生玻璃自带高光）
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

UIView *BDGlassCard(CGRect frame, CGFloat corner) {
    UIView *shell = [[UIView alloc] initWithFrame:frame];
    shell.backgroundColor = [UIColor clearColor];
    shell.layer.cornerRadius = corner;
    if (@available(iOS 13.0, *)) shell.layer.cornerCurve = kCACornerCurveContinuous;
    // 外投影（shell 不裁剪，专供投影；内容裁剪交给内层）
    shell.layer.shadowColor = [UIColor blackColor].CGColor;
    shell.layer.shadowOpacity = 0.10;
    shell.layer.shadowRadius = 10;
    shell.layer.shadowOffset = CGSizeMake(0, 3);
    shell.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shell.bounds
                                                        cornerRadius:corner].CGPath;

    UIView *glass = [[UIView alloc] initWithFrame:shell.bounds];
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    glass.backgroundColor = [UIColor clearColor];
    glass.layer.cornerRadius = corner;
    if (@available(iOS 13.0, *)) glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.clipsToBounds = YES;
    [shell addSubview:glass];
    if (!BDInstallGlassMaterial(glass)) glass.backgroundColor = BDCardBg();  // 兜底白卡
    return shell;
}

// 下载按钮 tinted glass：磨砂 + 琥珀 #E8A33D overlay(α0.85) + 白描边，文字白
void BDStyleAmberGlassButton(UIButton *btn) {
    if (!btn || btn.bounds.size.width < 1) return;
    UIColor *amber = [UIColor colorWithRed:0.9098 green:0.6392 blue:0.2392 alpha:1.0];  // #E8A33D
    btn.clipsToBounds = YES;
    btn.layer.borderWidth = 1;
    btn.layer.borderColor = [UIColor whiteColor].CGColor;
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    id effect = BDNewGlassEffect();
    if (!effect) effect = BDNewUltraThinEffect();
    if (!effect) { btn.backgroundColor = amber; return; }   // 兜底：琥珀实色
    @try {
        UIVisualEffectView *mat = [[UIVisualEffectView alloc] initWithEffect:effect];
        mat.frame = btn.bounds;
        mat.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        mat.userInteractionEnabled = NO;
        [btn insertSubview:mat atIndex:0];                  // titleLabel 之下
        UIView *tint = [[UIView alloc] initWithFrame:btn.bounds];
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        tint.userInteractionEnabled = NO;
        tint.backgroundColor = [UIColor colorWithRed:0.9098 green:0.6392 blue:0.2392 alpha:0.85];
        [btn insertSubview:tint aboveSubview:mat];
    } @catch (__unused NSException *e) {
        btn.backgroundColor = amber;
    }
}

// 径向 blob：中心色 → 同色透明，纯明度无色相
static CAGradientLayer *BDNewRadialBlob(CGRect frame, UIColor *center) {
    CAGradientLayer *g = [CAGradientLayer layer];
    g.type = kCAGradientLayerRadial;
    g.frame = frame;
    CGFloat r = 0, gg = 0, b = 0, a = 0;
    [center getRed:&r green:&gg blue:&b alpha:&a];
    UIColor *edge = [UIColor colorWithRed:r green:gg blue:b alpha:0];
    g.colors = [NSArray arrayWithObjects:(__bridge id)center.CGColor,
                                         (__bridge id)edge.CGColor, nil];
    g.startPoint = CGPointMake(0.5, 0.5);
    g.endPoint = CGPointMake(0.5, 1.0);
    return g;
}

void BDInstallGlassBackdrop(UIView *host) {
    if (!host || host.bounds.size.width < 1 || host.bounds.size.height < 1) return;
    CGFloat w = host.bounds.size.width, h = host.bounds.size.height;
    // blob 色随深浅色取值（纯明度）：浅色按定稿 白0.9/黑0.045；深色压幅值避免顶部过曝
    BOOL dark = host.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;

    UIView *deco = [[UIView alloc] initWithFrame:host.bounds];
    deco.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    deco.userInteractionEnabled = NO;
    deco.backgroundColor = [UIColor clearColor];
    deco.clipsToBounds = YES;

    // 白色高光 blob：顶部偏右，大半径径向渐变
    CGFloat s1 = MAX(w, h) * 1.5;
    [deco.layer addSublayer:BDNewRadialBlob(
        CGRectMake(w * 0.85 - s1 / 2, -s1 * 0.3, s1, s1),
        [UIColor colorWithWhite:1 alpha:dark ? 0.08 : 0.9])];
    // 黑色暗部 blob：左下角，极低透明度
    CGFloat s2 = MAX(w, h) * 1.2;
    [deco.layer addSublayer:BDNewRadialBlob(
        CGRectMake(-s2 * 0.25, h - s2 * 0.75, s2, s2),
        [UIColor colorWithWhite:0 alpha:dark ? 0.12 : 0.045])];

    // 超大低透明度水印
    UILabel *wm = [[UILabel alloc] initWithFrame:CGRectMake(0, h * 0.62, w, w * 0.28)];
    wm.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    wm.font = [UIFont systemFontOfSize:w * 0.22 weight:UIFontWeightBold];
    wm.textAlignment = NSTextAlignmentCenter;
    wm.text = @"BubbleDeck";
    wm.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return tc.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:1 alpha:0.05]
            : [UIColor colorWithWhite:0 alpha:0.05];
    }];
    [deco addSubview:wm];

    [host insertSubview:deco atIndex:0];   // 页面背景之上、scroll 之下，不随列表滚动
}

// ────── 布局 ──────

// 导航栏底边 y：navigationBar.frame 实测（Mio wpLayoutInContainer 同款——
// MMUIViewController 的 view 全屏布局，内容必须从导航栏底部开始）。
// v0.4.1 前用 safeAreaInsets 推算，在 inset 回写时序下会把内容顶进状态栏，已废弃。
CGFloat BDNavBarHeight(UIViewController *vc) {
    CGFloat top = 0;
    UINavigationController *nav = vc.navigationController;
    if (nav && !nav.navigationBarHidden && nav.navigationBar.superview) {
        CGRect nf = nav.navigationBar.frame;
        top = nf.origin.y + nf.size.height;
    }
    if (top < 1) top = 64; // view 未挂 window 时导航栏 frame 未就绪，兜底导航栏高度
    return top;
}

UIScrollView *BDNewScroll(UIViewController *vc) {
    CGFloat navH = BDNavBarHeight(vc);
    CGFloat w = vc.view.bounds.size.width;
    CGFloat h = vc.view.bounds.size.height - navH;
    if (h < 100) h = vc.view.bounds.size.height - navH;   // 尺寸未就绪时兜底
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, navH, w, h)];
    scroll.showsVerticalScrollIndicator = YES;
    scroll.alwaysBounceVertical = YES;
    scroll.backgroundColor = [UIColor clearColor];   // 透出底层纹理装饰，玻璃才有得磨
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:scroll];
    return scroll;
}

// 空状态提示卡
CGFloat BDEmptyHint(UIViewController *vc, UIScrollView *scroll, CGFloat y, NSString *text) {
    CGFloat w = vc.view.bounds.size.width;
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 84)];
    card.backgroundColor = BDCardBg();
    card.layer.cornerRadius = 15;
    if (@available(iOS 13.0, *)) card.layer.cornerCurve = kCACornerCurveContinuous;
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
CGFloat BDFooter(UIViewController *vc, UIScrollView *scroll, CGFloat y) {
    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(0, y + 4, vc.view.bounds.size.width, 20)];
    foot.font = [UIFont systemFontOfSize:12];
    foot.textColor = BDSecondaryText();
    foot.textAlignment = NSTextAlignmentCenter;
    foot.text = @"BubbleDeck · 本地气泡引擎";
    [scroll addSubview:foot];
    return y + 32;
}

// 通用行卡（左标题 + 右侧控件区已由调用方布置；高度 46，点按手势由调用方挂）
UIView *BDRowCard(UIViewController *vc, UIScrollView *scroll, CGFloat y,
                  NSString *title, SEL tapSel) {
    CGFloat w = vc.view.bounds.size.width;
    UIView *card = BDGlassCard(CGRectMake(15, y, w - 30, 46), 15);   // 分层玻璃行卡

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

// ────── 气泡包卡片内容 ──────
// 只做内容与布局，不画圆角：外层圆角由 TDBPackRowView 的裁剪容器提供
// badgeText 非空 = 不可用状态（灰色角标），替代「使用中」徽章/箭头

UIView *BDCardContentView(CGFloat w, NSString *title, NSString *subtitle,
                          UIImage *thumb, BOOL isActive, NSString *badgeText) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 76)];
    card.backgroundColor = [UIColor clearColor];
    // 直角：不设 cornerRadius。玻璃材质/兜底白底由外层（TDBPackRowView）安装，这里只做内容

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
        lb.backgroundColor = BDChipBg();
        lb.textAlignment = NSTextAlignmentCenter;
        lb.font = [UIFont boldSystemFontOfSize:20];
        lb.textColor = BDSecondaryText();
        lb.text = (title.length > 0)
            ? [[title substringToIndex:1] uppercaseString]
            : @"?";
        thumbView = lb;
    }
    thumbView.layer.cornerRadius = 12;
    if (@available(iOS 13.0, *)) thumbView.layer.cornerCurve = kCACornerCurveContinuous;
    thumbView.clipsToBounds = YES;
    [card addSubview:thumbView];

    CGFloat textX = tx + 48 + 14;
    CGFloat textW = w - textX - 70; // 右侧留徽章/箭头区

    // 文字块垂直居中：17 + 22 + 4 + 16 = 59，块中心 38 = 卡片中线
    UILabel *nameLb = [[UILabel alloc] initWithFrame:CGRectMake(textX, 17, textW, 22)];
    nameLb.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    nameLb.text = title;
    [card addSubview:nameLb];

    UILabel *subLb = [[UILabel alloc] initWithFrame:CGRectMake(textX, 43, textW, 16)];
    subLb.font = [UIFont systemFontOfSize:13];
    subLb.textColor = BDSecondaryText();
    subLb.text = subtitle;
    [card addSubview:subLb];

    CGFloat badgeX = w - 14 - 58;   // 右内边距 14，与左边距对称
    if (badgeText.length) {
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(badgeX, 27, 58, 22)];
        badge.backgroundColor = BDChipBg();
        badge.textColor = BDSecondaryText();
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 11;
        badge.clipsToBounds = YES;
        badge.text = badgeText;
        [card addSubview:badge];
    } else if (isActive) {
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(badgeX, 27, 58, 22)];
        badge.backgroundColor = BDTint();
        badge.textColor = [UIColor whiteColor];
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 11;
        badge.clipsToBounds = YES;
        badge.text = @"使用中";
        [card addSubview:badge];
    } else {
        UILabel *chevron = [[UILabel alloc] initWithFrame:CGRectMake(w - 14 - 20, 0, 20, 76)];
        chevron.text = @"›";
        chevron.font = [UIFont systemFontOfSize:20];
        chevron.textColor = BDSecondaryText();
        chevron.textAlignment = NSTextAlignmentCenter;
        [card addSubview:chevron];
    }

    return card;
}

// ────── 工具 ──────

NSString *BDFileSize(long long bytes) {
    if (bytes >= 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", bytes / 1024.0 / 1024.0];
    if (bytes >= 1024) return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%lld B", bytes];
}

// ────── 弹窗 ──────

void BDShowAlert(UIViewController *vc, NSString *title, NSString *message, NSString *okTitle) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:okTitle ?: @"好"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

void BDShowConfirm(UIViewController *vc, NSString *title, NSString *message,
                   NSString *okTitle, BOOL destructive, void (^onConfirm)(void)) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:okTitle
                                          style:destructive ? UIAlertActionStyleDestructive
                                                            : UIAlertActionStyleDefault
                                        handler:^(__unused UIAlertAction *act) {
        if (onConfirm) onConfirm();
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消"
                                          style:UIAlertActionStyleCancel
                                        handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}
