//
//  TDPackLoader.m
//  BubbleDeck
//
//  目录即发行形态。引擎直读 packs/<气泡包名>/，零解包、零缓存记录。
//

#import "TDPackLoader.h"

@implementation TDPackLoader

// ────── 目录约定 ──────

+ (NSString *)packsRoot {
    NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
                      firstObject] stringByAppendingPathComponent:@"BubbleDeck/packs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return dir;
}

// ────── 主流程 ──────

+ (NSArray<NSString *> *)availablePacks {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *f in [fm contentsOfDirectoryAtPath:self.packsRoot error:nil]) {
        if ([self packDirForName:f]) [names addObject:f];
    }
    return [names sortedArrayUsingSelector:@selector(localizedCompare:)];
}

+ (nullable NSString *)packDirForName:(NSString *)name {
    if (!name.length || [name containsString:@"/"]) return nil;
    NSString *p = [[self packsRoot] stringByAppendingPathComponent:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:p isDirectory:&isDir] || !isDir) return nil;
    // 只认含 info.json 的目录（半拷贝状态不进列表）
    return [fm fileExistsAtPath:[p stringByAppendingPathComponent:@"info.json"]] ? p : nil;
}

@end
