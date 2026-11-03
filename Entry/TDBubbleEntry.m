//
//  TDBubbleEntry.m
//  BubbleDeck
//
//  注入总入口（v0.5.0 薄壳化，架构对齐 Mio SettingEntryHook）：
//    气泡引擎 hook + 微信"第三方插件"页注册（WCPluginsMgr，机制与 ThemeDeck/Mio 同款）。
//  运行时类 BubbleDeckEntryVC 只是门面：viewDidAppear 一次性把自己在导航栈里
//  替换成真实的 TDBMainPageVC（编译期类，Entry/Pages/ 下四页各自独立文件），
//  原生导航栏的标题/返回键随 push/pop 自动工作。
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
// 方案 A：栈替换从 viewDidAppear 提前到 viewWillAppear——push 动画首帧前就换成
// 主页，动画直接滑进主页内容，空白门面页从视觉上消失。

static CFAbsoluteTime s_entryTViewDidLoad = 0;
static CFAbsoluteTime s_entryTViewWillAppear = 0;

// 一次性进场：把自己在导航栈里替换成主页（back 直接回到微信插件列表，
// 不会停在空白门面页）。viewWillAppear 优先做；bounds 未就绪则由 viewDidAppear 兜底重试。
static void BDEnterMainIfNeeded(UIViewController *vc, CFAbsoluteTime t0, NSString *from) {
    if (objc_getAssociatedObject(vc, "bdEntered")) return;
    if (vc.view.bounds.size.width < 1) {
        TDLog(@"DEV", @"[Timing] %@ bounds 未就绪，进场延后重试", from);
        return;
    }
    objc_setAssociatedObject(vc, "bdEntered", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UINavigationController *nav = vc.navigationController;
    TDBMainPageVC *main = [[TDBMainPageVC alloc] init];
    if (nav && nav.viewControllers.count > 0 && [nav.viewControllers lastObject] == vc) {
        NSMutableArray *stack = [nav.viewControllers mutableCopy];
        [stack replaceObjectAtIndex:stack.count - 1 withObject:main];
        [nav setViewControllers:stack animated:NO];
        TDLog(@"DEV", @"[Entry] 主页已替换进栈（%@）", from);
    } else if (nav) {
        [nav pushViewController:main animated:YES];
        TDLog(@"DEV", @"[Entry] 主页已 push（%@）", from);
    } else {
        // 兜底：无导航栈则模态 present（极端版本差异）
        UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:main];
        [vc presentViewController:wrap animated:YES completion:nil];
        TDLog(@"DEV", @"[Entry] 无导航栈，模态 present 兜底（%@）", from);
    }
    TDLog(@"DEV", @"[Timing] %@ 进场替换完成，耗时 %.0fms",
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

    // 门面只闪现一瞬（push 首帧前即被主页替换），底色与插件页保持一致防白闪
    if (@available(iOS 13.0, *)) {
        ((UIViewController *)self).view.backgroundColor = BDPageBg();
    }

    BDEnterMainIfNeeded((UIViewController *)self, t0, @"viewWillAppear");
}

static void bdEntryViewDidAppear(id self, SEL _cmd, BOOL animated) {
    Method m = class_getInstanceMethod(objc_getClass("UIViewController"), _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);

    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    // 这段 ≈ push 动画时长：appear 是动画播完才回调的最晚时点（旧版延迟主体）
    TDLog(@"DEV", @"[Timing] 门面 viewDidAppear（距 viewWillAppear %.0fms，≈push 动画时长）",
          (t0 - s_entryTViewWillAppear) * 1000);

    // viewWillAppear 没替换成（bounds 未就绪等）→ 此处兜底重试
    BDEnterMainIfNeeded((UIViewController *)self, t0, @"viewDidAppear");
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
