//
//  TDBubbleEntry.m
//  BubbleDeck
//
//  注入总入口（v0.5.0 薄壳化，架构对齐 Mio SettingEntryHook）：
//    气泡引擎 hook + 微信"第三方插件"页注册（WCPluginsMgr，机制与 ThemeDeck/Mio 同款）。
//  运行时类 BubbleDeckEntryVC 是常驻容器：把 TDBMainPageVC 以 containment
//  （addChildViewController）挂载进自己（编译期类，Entry/Pages/ 下四页各自独立文件），
//  push 动画期间主页内容即在屏（栈替换会被 UIKit 推迟到转场结束，实测 529ms 空白期，
//  已弃）。子页面从主页真实 push，原生导航栏的标题/返回键随 push/pop 自动工作。
//  另外垫 UIViewController (TDBCompat)：微信分享握手无条件对导航栈顶 VC 调
//  presentingModalViewController（iOS5 前老接口，UIKit 从未有过），不垫必闪退
//  （Mio MioMMCompat 同款原则：不继承微信类，契约自己垫）。
//

#import "TDBubbleEntry.h"
#import "Pages/TDBPages.h"
#import "../Core/TDLog.h"
#import "../Core/TDConfig.h"
#import "../Core/TDLicense.h"
#import "../Engine/TDBubbleEngine.h"
#import "TDBUI.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ────── 基类探测（Mio WPGetBaseClass 同款） ──────
static Class BDGetBaseClass(void) {
    Class cls = objc_getClass("MMUIViewController");
    if (cls) return cls;
    return objc_getClass("UIViewController");
}

// ────── 微信老 API 兼容（Mio MioMMCompat 同款，category 补在 UIViewController 上
// 一次覆盖全部受害类；MMUIViewController 自带实现，方法查找先命中类自身，行为不变） ──────
@implementation UIViewController (TDBCompat)
- (UIViewController *)presentingModalViewController {
    return [self presentedViewController];
}
@end

// ────── 门面 VC 的生命周期 IMP（挂在运行时类对上） ──────
// 时序打点：量化「点击插件 → 主页可见」各段耗时。
// 进场 = 子 VC 挂载（containment）：实测栈替换在转场期间会被 UIKit 推迟到动画
// 结束才执行（日志：换栈 1ms 发出，主页 viewDidLoad 拖到 529ms 后），空白期原样。
// containment 不碰导航栈：主页内容在 push 动画期间就在门面 view 上，零空白期；
// 子页面（商店/主题/设置）仍从主页真实 push，导航栈行为不变。

static CFAbsoluteTime s_entryTViewDidLoad = 0;
static CFAbsoluteTime s_entryTViewWillAppear = 0;

// 把主页挂载为门面的子 VC（一次性；viewWillAppear 优先，bounds 未就绪由 viewDidAppear 兜底）
static void BDMountMainIfNeeded(UIViewController *vc, CFAbsoluteTime t0, NSString *from) {
    if (objc_getAssociatedObject(vc, "bdChild")) return;
    if (vc.view.bounds.size.width < 1) {
        TDLog(@"DEV", @"[Timing] %@ bounds 未就绪，主页挂载延后重试", from);
        return;
    }
    objc_setAssociatedObject(vc, "bdChild", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    TDBMainPageVC *main = [[TDBMainPageVC alloc] init];
    [vc addChildViewController:main];
    main.view.frame = vc.view.bounds;
    main.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:main.view];
    [main didMoveToParentViewController:vc];
    TDLog(@"DEV", @"[Timing] 主页已挂载为子 VC（%@），耗时 %.0fms",
          from, (CFAbsoluteTimeGetCurrent() - t0) * 1000);
}

static void bdEntryViewDidLoad(id self, SEL _cmd) {
    // 调用父类 viewDidLoad
    Method m = class_getInstanceMethod(objc_getClass("UIViewController"), _cmd);
    if (m) ((void (*)(id, SEL))method_getImplementation(m))(self, _cmd);

    s_entryTViewDidLoad = CFAbsoluteTimeGetCurrent();
    ((UIViewController *)self).title = @"BubbleDeck";
    TDLog(@"DEV", @"[Timing] 门面 viewDidLoad");
}

static void bdEntryViewWillAppear(id self, SEL _cmd, BOOL animated) {
    Method m = class_getInstanceMethod(objc_getClass("UIViewController"), _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    s_entryTViewWillAppear = t0;
    TDLog(@"DEV", @"[Timing] 门面 viewWillAppear（距 viewDidLoad %.0fms）",
          (t0 - s_entryTViewDidLoad) * 1000);

    // 底色与主页一致防白闪（主页子 VC 随后全幅覆盖）
    if (@available(iOS 13.0, *)) {
        ((UIViewController *)self).view.backgroundColor = BDPageBg();
    }

    BDMountMainIfNeeded((UIViewController *)self, t0, @"viewWillAppear");
}

static void bdEntryViewDidAppear(id self, SEL _cmd, BOOL animated) {
    Method m = class_getInstanceMethod(objc_getClass("UIViewController"), _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    // 这段 ≈ push 动画时长（主页已随动画在屏，此数字仅剩观测意义）
    TDLog(@"DEV", @"[Timing] 门面 viewDidAppear（距 viewWillAppear %.0fms，≈push 动画时长）",
          (t0 - s_entryTViewWillAppear) * 1000);

    // viewWillAppear 没挂载成（bounds 未就绪等）→ 此处兜底重试
    BDMountMainIfNeeded((UIViewController *)self, t0, @"viewDidAppear");
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
