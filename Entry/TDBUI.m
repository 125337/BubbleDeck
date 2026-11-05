//
//  TDBUI.m
//  BubbleDeck
//
//  插件页共享自绘组件库实现（逻辑自 v0.4.x TDBubbleEntry.m 平移，业务不变）。
//

#import "TDBUI.h"
#import <objc/runtime.h>

// ────── 配色 ──────

// 页面背景：iOS 分组列表的浅灰底，让白色卡片有轮廓
UIColor *BDPageBg(void) {
    if (@available(iOS 13.0, *)) return [UIColor systemGroupedBackgroundColor];
    return [UIColor colorWithRed:0.949 green:0.949 blue:0.969 alpha:1.0];
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

// ────── 气泡包卡片 ──────
// packName = nil 表示「微信默认」卡；isActive 决定右侧徽章样式；
// badgeText 非空 = 不可用状态（灰显 + 灰色角标）

UIView *BDMakeCard(CGFloat y, CGFloat w,
                   NSString *packName, NSString *title,
                   NSString *subtitle, UIImage *thumb, BOOL isActive, NSString *badgeText) {
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, w - 30, 76)];
    card.backgroundColor = BDCardBg();
    card.layer.cornerRadius = 15;
    if (@available(iOS 13.0, *)) card.layer.cornerCurve = kCACornerCurveContinuous;
    if (@available(iOS 13.0, *)) {
        if (isActive && !badgeText) card.layer.borderWidth = 1.5, card.layer.borderColor = BDTint().CGColor;
    }
    if (badgeText.length) card.alpha = 0.6;

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

    if (badgeText.length) {
        UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(w - 30 - 66, 28, 58, 22)];
        badge.backgroundColor = BDChipBg();
        badge.textColor = BDSecondaryText();
        badge.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        badge.textAlignment = NSTextAlignmentCenter;
        badge.layer.cornerRadius = 11;
        badge.clipsToBounds = YES;
        badge.text = badgeText;
        [card addSubview:badge];
    } else if (isActive) {
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

// ────── 工具 ──────

// 包图片数：统计解包目录里的位图文件
NSInteger BDPackImageCount(NSString *dir) {
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
