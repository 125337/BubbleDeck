//
//  TDBMainPageVC.m
//  BubbleDeck
//
//  主页（逻辑自 v0.4.x TDBubbleEntry.m 平移，业务不变）：
//  Logo hero（64pt + 版本 + 状态胶囊）+ 启用插件总开关卡（含三入口）+ 兑换激活码行。
//  三入口 / 激活成功后 push 对应子页（真实 VC，原生导航栏返回）。
//

#import "TDBPages.h"
#import "../TDBUI.h"
#import "../../Core/TDLog.h"
#import "../../Core/TDConfig.h"
#import "../../Core/TDLicense.h"
#import <objc/runtime.h>

@implementation TDBMainPageVC

- (void)viewDidLoad {
    // 调用父类 viewDidLoad
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL))method_getImplementation(m))(self, _cmd);
    self.title = @"BubbleDeck";
    TDLog(@"DEV", @"[Timing] 主页 viewDidLoad");
}

- (void)viewWillAppear:(BOOL)animated {
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);

    self.view.backgroundColor = BDPageBg();
    if (self.view.bounds.size.width < 1) {
        TDLog(@"DEV", @"[Timing] 主页 viewWillAppear bounds 未就绪，构建延后");
        return; // bounds 未就绪，等下次 appear
    }
    [self buildPage];
    TDLog(@"DEV", @"[Timing] 主页 UI 构建完成，耗时 %.1fms（bounds %@）",
          (CFAbsoluteTimeGetCurrent() - t0) * 1000, NSStringFromCGRect(self.view.bounds));
}

// ────── 页面构建（viewWillAppear 全量重建，量小保证状态新鲜） ──────

- (void)buildPage {
    for (UIView *sub in self.view.subviews) [sub removeFromSuperview];

    CGFloat w = self.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(self);

    CGFloat wIn = w - 30;
    CGFloat y = 46;   // 静态下移：内容块短，顶在导航栏下面显得头重脚轻

    // ── 头部：图标 + 版本 + 状态胶囊（标题在微信导航栏上，不重复） ──
    {
        CGFloat logoSize = 64;
        UIView *logo = [[UIView alloc] initWithFrame:CGRectMake((w - logoSize) / 2, y, logoSize, logoSize)];
        logo.backgroundColor = BDTint();
        logo.layer.cornerRadius = 12;
        if (@available(iOS 13.0, *)) logo.layer.cornerCurve = kCACornerCurveContinuous;
        UILabel *bl = [[UILabel alloc] initWithFrame:logo.bounds];
        bl.text = @"B";
        bl.font = [UIFont boldSystemFontOfSize:30];
        bl.textColor = [UIColor whiteColor];
        bl.textAlignment = NSTextAlignmentCenter;
        [logo addSubview:bl];
        [scroll addSubview:logo];
        y += logoSize + 10;

        // 版本行（导航栏已有 BubbleDeck 标题，不再画大标题）
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
        if (@available(iOS 13.0, *)) pill.layer.cornerCurve = kCACornerCurveContinuous;
        pill.clipsToBounds = YES;
        pill.textColor = pillActive ? [UIColor whiteColor] : BDSecondaryText();
        pill.backgroundColor = pillActive ? BDTint() : BDChipBg();
        [scroll addSubview:pill];
        y += 36;
    }

    // ── 启用插件卡：总开关 + 三入口 ──
    {
        UIView *card = [[UIView alloc] initWithFrame:CGRectMake(15, y, wIn, 128)];
        card.backgroundColor = BDCardBg();
        card.layer.cornerRadius = 15;
        if (@available(iOS 13.0, *)) card.layer.cornerCurve = kCACornerCurveContinuous;

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, wIn - 100, 48)];
        lb.font = [UIFont systemFontOfSize:15];
        lb.text = @"启用插件";
        [card addSubview:lb];

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(wIn - 66, 8, 51, 31)];
        sw.on = [TDConfig pluginEnabled];
        [sw addTarget:self action:@selector(bdEnableSwitch:)
     forControlEvents:UIControlEventValueChanged];
        [card addSubview:sw];

        // 三入口：下载气泡 / 更换气泡 / 设置中心
        NSArray *titles = @[@"下载气泡", @"更换气泡", @"设置中心"];
        NSArray *symbols = @[@"arrow.down.circle", @"paintbrush", @"gear"];
        CGFloat btnW = (wIn - 32 - 16) / 3;
        for (NSInteger i = 0; i < 3; i++) {
            UIControl *btn = [[UIControl alloc] initWithFrame:CGRectMake(16 + i * (btnW + 8), 54, btnW, 62)];
            btn.backgroundColor = BDChipBg();
            btn.layer.cornerRadius = 12;
            if (@available(iOS 13.0, *)) btn.layer.cornerCurve = kCACornerCurveContinuous;

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
            [btn addTarget:self action:@selector(bdIconTap:)
          forControlEvents:UIControlEventTouchUpInside];
            [card addSubview:btn];
        }
        [scroll addSubview:card];
        y += 128 + 12;
    }

    // ── 兑换激活码行 ──
    BDRowCard(self, scroll, y, @"兑换激活码", NSSelectorFromString(@"bdRedeemTap:"));
    y += 46 + 12;

    y = BDFooter(self, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 交互 ──────

// 总开关
- (void)bdEnableSwitch:(UISwitch *)sw {
    [TDConfig setPluginEnabled:sw.on];
    TDLog(@"DEV", @"[Plugin] 总开关 %@", sw.on ? @"开" : @"关");
    [self buildPage];
}

// 三入口：push 对应子页
- (void)bdIconTap:(UIControl *)btn {
    NSNumber *page = objc_getAssociatedObject(btn, "page");
    UIViewController *target;
    switch (page.integerValue) {
        case 1:  target = [[TDBStorePageVC alloc] init];    break;
        case 2:  target = [[TDBThemePageVC alloc] init];    break;
        case 3:  target = [[TDBSettingsPageVC alloc] init]; break;
        default: return;
    }
    [self.navigationController pushViewController:target animated:YES];
}

// 兑换激活码（激活唯一入口）→ 成功 push 商店页
- (void)bdRedeemTap:(UIControl *)btn {
    // 绑定主键就是 wxid：抓不到（未登录/早期）直接本地拦，不给发请求
    if (![TDLicense currentWxid]) {
        BDShowAlert(self, @"无法激活",
                    @"请先登录微信后再激活（激活码会绑定当前微信号）", @"好");
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
    __weak typeof(self) wv = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"激活" style:UIAlertActionStyleDefault
        handler:^(__unused UIAlertAction *a) {
        NSString *code = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!code.length) return;
        TDLog(@"LIC", @"[Activate] 提交激活码（尾 4 位: %@）",
              code.length >= 4 ? [code substringFromIndex:code.length - 4] : code);
        [TDLicense activateLicense:code completion:^(BOOL ok, NSString *message) {
            __strong typeof(wv) v = wv;
            UIAlertController *done = [UIAlertController alertControllerWithTitle:
                ok ? @"激活成功" : @"激活失败"
                message:message
                preferredStyle:UIAlertControllerStyleAlert];
            [done addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel
                handler:^(__unused UIAlertAction *x) {
                if (!ok) return;
                __strong typeof(wv) v2 = wv;
                if (v2 && v2.isViewLoaded) {
                    // activate 内部已同步报到，push 商店页：新入账的包带着 [下载] 按钮等着
                    [v2.navigationController pushViewController:[[TDBStorePageVC alloc] init]
                                                       animated:YES];
                }
            }]];
            [v presentViewController:done animated:YES completion:nil];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
