//
//  TDBSettingsPageVC.m
//  BubbleDeck
//
//  设置页（逻辑自 v0.4.x TDBubbleEntry.m 平移，业务不变）：
//  日志开关 / 重新加载 / 关于（版本 + 设备尾号）。
//

#import "TDBPages.h"
#import "../TDBUI.h"
#import "../../Core/TDLog.h"
#import "../../Core/TDConfig.h"
#import "../../Core/TDLicense.h"
#import "../../Engine/TDBubbleEngine.h"
#import <objc/runtime.h>

@implementation TDBSettingsPageVC

- (void)viewDidLoad {
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL))method_getImplementation(m))(self, _cmd);
    self.title = @"设置中心";
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
    BDInstallGlassBackdrop(self.view);   // 中性纹理装饰层：背景之上、scroll 之下，不随列表滚动

    CGFloat w = self.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(self);

    CGFloat wIn = w - 30;
    CGFloat y = 16;

    // 日志开关卡
    {
        UIView *card = BDGlassCard(CGRectMake(15, y, wIn, 46), 15);   // 分层玻璃：行卡

        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, wIn - 100, 46)];
        lb.font = [UIFont systemFontOfSize:15];
        lb.text = @"日志记录";
        [card addSubview:lb];

        UISwitch *logSw = [[UISwitch alloc] initWithFrame:CGRectMake(wIn - 66, 8, 51, 31)];
        logSw.on = [_TDLogManager fileLoggingEnabled];
        [logSw addTarget:self action:@selector(bdLogSwitch:)
      forControlEvents:UIControlEventValueChanged];
        [card addSubview:logSw];
        [scroll addSubview:card];
        y += 46 + 12;
    }

    // 重新加载行
    BDRowCard(self, scroll, y, @"重新加载气泡包", NSSelectorFromString(@"bdReloadTap:"));
    y += 46 + 12;

    // 关于卡
    {
        UIView *card = BDGlassCard(CGRectMake(15, y, wIn, 64), 15);   // 分层玻璃：行卡

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

    y = BDFooter(self, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 交互 ──────

// 重新加载
- (void)bdReloadTap:(UIButton *)btn {
    [TDBubbleEngine purgeCaches];       // 清负缓存，包内容变更即时生效
    [TDBStorePageVC resetFetchState];   // 在线清单允许重试
    BDShowAlert(self, @"已重新加载",
                [NSString stringWithFormat:@"当前 %lu 个气泡包可用。",
                 (unsigned long)[TDConfig availablePacks].count],
                @"好");
    TDLog(@"DEV", @"[Pack] 重新加载，packs=%@", [TDConfig availablePacks]);
}

// 日志开关
- (void)bdLogSwitch:(UISwitch *)sw {
    [_TDLogManager setFileLoggingEnabled:sw.on];
    TDLog(@"DEV", @"[Log] 文件日志 %@", sw.on ? @"开" : @"关");
}

@end
