//
//  TDConfig.m
//  BubbleDeck
//
//  注意：activePack / activePackDir 走内存缓存——气泡取图处在微信聊天页热路径上
//  （滚一下聊天记录可连发几十次），绝不能每次读 prefs.plist（ThemeDeck 的启动 IO 风暴教训）。
//

#import "TDConfig.h"
#import "TDLog.h"
#import "../Engine/TDPackLoader.h"
#import "../Engine/TDBubbleEngine.h"

NSString * const kTDVersion = @"0.5.0";

static NSString *TDPrefsPath(void) {
    NSString *prefs = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)
                       firstObject];
    prefs = [prefs stringByAppendingPathComponent:@"Preferences/BubbleDeck"];
    [[NSFileManager defaultManager] createDirectoryAtPath:prefs withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return [prefs stringByAppendingPathComponent:@"prefs.plist"];
}

// ── 内存缓存 ──
static BOOL     s_packLoaded = NO;    // 区分"未加载"与"无气泡包"
static NSString *s_pack = nil;
static BOOL     s_dirResolved = NO;   // 区分"未解析"与"解析过但没有"
static NSString *s_packDir = nil;

// 包来源（prefs: sources = {包名: @"online"}）。热路径读（闸门），走内存缓存。
static NSDictionary *s_sources = nil;
static BOOL s_sourcesLoaded = NO;

// 插件总开关（prefs: pluginEnabled，缺省 YES）。热路径读（引擎闸门第一道），走内存缓存。
static BOOL s_enabled = YES;
static BOOL s_enabledLoaded = NO;

static NSDictionary *BDSources(void) {
    if (!s_sourcesLoaded) {
        id v = [NSMutableDictionary dictionaryWithContentsOfFile:TDPrefsPath()][@"sources"];
        s_sources = [v isKindOfClass:[NSDictionary class]] ? v : @{};
        s_sourcesLoaded = YES;
    }
    return s_sources;
}

@implementation TDConfig

+ (nullable NSString *)activePack {
    if (!s_packLoaded) {
        NSString *name = [NSMutableDictionary dictionaryWithContentsOfFile:TDPrefsPath()][@"activePack"];
        s_pack = name.length ? name : nil;
        s_packLoaded = YES;
        s_dirResolved = NO;
        s_packDir = nil;
    }
    return s_pack;
}

+ (void)setActivePack:(nullable NSString *)name {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:TDPrefsPath()] ?: [NSMutableDictionary dictionary];
    if (name.length) d[@"activePack"] = name;
    else [d removeObjectForKey:@"activePack"];
    [d writeToFile:TDPrefsPath() atomically:YES];

    s_pack = name.length ? name : nil;
    s_packLoaded = YES;
    s_dirResolved = NO;
    s_packDir = nil;

    // 新包的文件名集合不同，旧负缓存会错误放行原实现
    [TDBubbleEngine purgeCaches];
}

+ (NSString *)packsRoot {
    return [TDPackLoader packsRoot];
}

+ (NSArray<NSString *> *)availablePacks {
    return [TDPackLoader availablePacks];
}

+ (nullable NSString *)activePackDir {
    NSString *p = [self activePack];
    if (!p) return nil;
    if (!s_dirResolved) {
        s_packDir = [TDPackLoader packDirForName:p];
        s_dirResolved = YES;
    }
    return s_packDir;
}

+ (BOOL)pluginEnabled {
    if (!s_enabledLoaded) {
        NSNumber *v = [NSMutableDictionary dictionaryWithContentsOfFile:TDPrefsPath()][@"pluginEnabled"];
        s_enabled = v ? [v boolValue] : YES;
        s_enabledLoaded = YES;
    }
    return s_enabled;
}

+ (void)setPluginEnabled:(BOOL)enabled {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:TDPrefsPath()] ?: [NSMutableDictionary dictionary];
    d[@"pluginEnabled"] = @(enabled);
    [d writeToFile:TDPrefsPath() atomically:YES];

    s_enabled = enabled;
    s_enabledLoaded = YES;

    [TDBubbleEngine purgeCaches];
}

+ (NSString *)sourceForPack:(NSString *)name {
    if (!name.length) return @"imported";
    NSString *s = BDSources()[name];
    return [s isKindOfClass:[NSString class]] && [s isEqualToString:@"online"] ? @"online" : @"imported";
}

+ (void)setPackSource:(NSString *)name source:(NSString *)source {
    if (!name.length) return;
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:TDPrefsPath()]
                              ?: [NSMutableDictionary dictionary];
    NSMutableDictionary *src = [[d[@"sources"] isKindOfClass:[NSDictionary class]]
                                ? d[@"sources"] : @{} mutableCopy] ?: [NSMutableDictionary dictionary];
    if ([source isEqualToString:@"online"]) src[name] = @"online";
    else [src removeObjectForKey:name];
    d[@"sources"] = src;
    [d writeToFile:TDPrefsPath() atomically:YES];

    s_sources = src;
    s_sourcesLoaded = YES;
    TDLog(@"DEV", @"[Source] %@ → %@", name, src[name] ?: @"imported");
}

@end
