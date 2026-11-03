//
//  TDBubbleEngine.m
//  BubbleDeck
//
//  气泡供给核心（V1 换图）：
//    hook -[MMThemeManager imageNamed:] 与 imageNamed:warnIfNotFound: 两口（气泡 PNG
//    实证取图路线；不 hook WCSVGImage——那是 SVG 图标族，气泡用不上）。
//
//  查图规则：
//    ① 只接 ChatRoom_Bubble_* 前缀的请求，其余一律放行原实现（非气泡零影响）
//    ② 亮暗配对：暗屏时优先 stem+"Dark"（ChatRoom_Bubble_Text_Sender_Green
//       → ChatRoom_Bubble_Text_Sender_Green_Dark，同 ThemeDeck 的 _Dark 机制），
//       包里没有暗色变体自动回落亮色图
//    ③ 尺寸档：@3x → @2x → 裸 png（请求点名 @3x 时优先 @3x）
//    ④ miss 回官方：包里没有直接放行原图，微信缺什么补什么的感觉不存在
//    ⑤ 负缓存：整个链 miss 过的名字直接放行（包是静态的，同名请求不会突然出现）
//

#import "TDBubbleEngine.h"
#import "TDConfig.h"
#import "TDLog.h"
#import "../Core/TDLicense.h"
#import "../libs/substrate.h"
#import <objc/runtime.h>
#import <UIKit/UIKit.h>

// 原实现：MMThemeManager
static UIImage *(*g_orig_MMImageNamed)(id, SEL, NSString *);
static UIImage *(*g_orig_MMImageNamedWarn)(id, SEL, NSString *, BOOL);

// ── 亮暗状态缓存 ──
// UIScreen.traitCollection 是 UIKit API，只能在主线程调。微信在分享/文件导入等流程
// 会从后台线程走取图口，后台线程直接查会崩（实测闪退）。策略：主线程调用时顺手刷新
// 缓存；后台线程用最近一次主线程缓存值（首查前默认亮色）。
static BOOL s_darkKnown = NO;
static BOOL s_dark = NO;

@implementation TDBubbleEngine

+ (BOOL)currentDarkState {
    if ([NSThread isMainThread]) {
        s_dark = [UIScreen mainScreen].traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
        s_darkKnown = YES;
        return s_dark;
    }
    return s_darkKnown ? s_dark : NO;
}

// ── 图片缓存 ──────────────────────────────────────────────────────────────────
// 命中图走 NSCache（正缓存按解析路径，负缓存按请求名）——否则每次命中都磁盘读+解码。
static NSCache<NSString *, UIImage *> *s_imgCache = nil;   // key: 解析后的文件路径
static NSCache<NSString *, NSNull *>  *s_negCache = nil;   // key: 请求名（含 @3x），包内没有

+ (void)initialize {
    if (self == [TDBubbleEngine class]) {
        s_imgCache = [NSCache new];
        s_imgCache.countLimit = 120;
        s_negCache = [NSCache new];
        s_negCache.countLimit = 1000;
    }
}

+ (void)purgeCaches {
    [s_imgCache removeAllObjects];
    [s_negCache removeAllObjects];
    TDLog(@"ALT", @"气泡缓存已清空（切换气泡包）");
}

// ── 包内查气泡图 ──────────────────────────────────────────────────────────────

+ (nullable UIImage *)loadImageAtPath:(NSString *)path {
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (!img) return nil;
    CGFloat scale = 1;
    if ([path hasSuffix:@"@3x.png"]) scale = 3;
    else if ([path hasSuffix:@"@2x.png"]) scale = 2;
    if (scale == 1 || !img.CGImage) return img;
    return [UIImage imageWithCGImage:img.CGImage scale:scale orientation:UIImageOrientationUp];
}

+ (nullable UIImage *)bubbleImageForName:(nullable NSString *)name {
    if (name.length == 0 || [name containsString:@"/"]) return nil;  // 含路径成分一律不动

    // ① 只接气泡族，其余直接放行（省去负缓存写入）
    if (![name hasPrefix:@"ChatRoom_Bubble_"]) return nil;

    // 收费闸门（V2 按包授权）：本地导入包免费放行；在线包需清单未超期且 owned。
    //    全内存判断，热路径零 IO。
    NSString *active = [TDConfig activePack];
    if (active
        && [[TDConfig sourceForPack:active] isEqualToString:@"online"]
        && ![TDLicense gateOpenForPack:active]) return nil;   // 无授权 → 放行官方图

    // 负缓存：整链 miss 过的名字，直接放行
    if ([s_negCache objectForKey:name]) return nil;

    NSString *dir = [TDConfig activePackDir];   // 内存缓存，热路径安全
    if (!dir) return nil;

    // 剥 @3x/@2x 后缀与 .png 扩展，得到干净 stem
    NSString *stem = name;
    BOOL threeX = NO;
    if ([stem hasSuffix:@"@3x"]) { stem = [stem substringToIndex:stem.length - 3]; threeX = YES; }
    else if ([stem hasSuffix:@"@2x"]) { stem = [stem substringToIndex:stem.length - 3]; }
    NSString *ext = stem.pathExtension.lowercaseString;
    if (ext.length) stem = [stem stringByDeletingPathExtension];

    // ②③ 组装候选：暗屏先 _Dark 变体再亮色；每档 @3x → @2x → 裸 png
    BOOL dark = [self currentDarkState];
    NSMutableArray<NSString *> *stems = [NSMutableArray array];
    if (dark && ![stem hasSuffix:@"_Dark"]) [stems addObject:[stem stringByAppendingString:@"_Dark"]];
    [stems addObject:stem];

    NSArray<NSString *> *exts = threeX
        ? @[ @"@3x.png", @"@2x.png", @".png" ]
        : @[ @"@2x.png", @"@3x.png", @".png" ];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *assetsDir = [dir stringByAppendingPathComponent:@"Assets"];
    for (NSString *s in stems) {
        for (NSString *e in exts) {
            NSString *p = [assetsDir stringByAppendingPathComponent:[s stringByAppendingString:e]];
            if (![fm fileExistsAtPath:p]) continue;
            UIImage *cached = [s_imgCache objectForKey:p];
            if (!cached) {
                cached = [self loadImageAtPath:p];
                if (cached) [s_imgCache setObject:cached forKey:p cost:1];
            }
            if (cached && ![s isEqualToString:stem]) {
                TDLogD(@"ALT", @"[暗色配对] %@ → %@.png", name, s);
            }
            return cached;
        }
    }
    // ⑤ 全 miss：记负缓存
    [s_negCache setObject:[NSNull null] forKey:name];
    TDLogD(@"ALT", @"[miss] %@ 包内没有，放行原图", name);
    return nil;
}

// ── MMThemeManager 双入口 ─────────────────────────────────────────────────────

static UIImage *bd_MMImageNamed(id self, SEL _cmd, NSString *name) {
    UIImage *img = [TDBubbleEngine bubbleImageForName:name];
    if (img) {
        TDLogD(@"ALT", @"[命中] %@", name);
        return img;
    }
    return g_orig_MMImageNamed(self, _cmd, name);
}

static UIImage *bd_MMImageNamedWarn(id self, SEL _cmd, NSString *name, BOOL warn) {
    UIImage *img = [TDBubbleEngine bubbleImageForName:name];
    if (img) {
        TDLogD(@"ALT", @"[命中] %@", name);
        return img;
    }
    return g_orig_MMImageNamedWarn(self, _cmd, name, warn);
}

// ── Hook 安装 ─────────────────────────────────────────────────────────────────

+ (void)installHooks {
    Class mgrCls = NSClassFromString(@"MMThemeManager");
    if (!mgrCls) {
        TDLog(@"ALT", @"MMThemeManager 不存在，气泡 hook 跳过");
        return;
    }
    struct { SEL sel; IMP imp; IMP *orig; const char *tag; } hooks[] = {
        { @selector(imageNamed:),                (IMP)bd_MMImageNamed,     (IMP *)&g_orig_MMImageNamed,     "imageNamed:" },
        { @selector(imageNamed:warnIfNotFound:), (IMP)bd_MMImageNamedWarn, (IMP *)&g_orig_MMImageNamedWarn, "imageNamed:warnIfNotFound:" },
    };
    for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
        if (![mgrCls instancesRespondToSelector:hooks[i].sel]) {
            TDLog(@"ALT", @"跳过（类无此方法）: %@", NSStringFromSelector(hooks[i].sel));
            continue;
        }
        MSHookMessageEx(mgrCls, hooks[i].sel, hooks[i].imp, hooks[i].orig);
        TDLog(@"ALT", @"hooked MMThemeManager %@", NSStringFromSelector(hooks[i].sel));
    }
    TDLog(@"ALT", @"激活气泡包: %@ 或未激活（走原实现）", [TDConfig activePack] ?: @"（无）");
}

@end
