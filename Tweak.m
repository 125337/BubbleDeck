//
//  Tweak.m
//  BubbleDeck
//
//  注入入口：微信进程加载后调用 TDBubbleEntry。
//

#import <Foundation/Foundation.h>
#import <stdatomic.h>
#import "Entry/TDBubbleEntry.h"

__attribute__((constructor))
static void BubbleDeckInitialize() {
    // 防重复加载：dylib 被加载两次会让所有取图穿两层 hook。保护 + 保留加载计数证据。
    static dispatch_once_t onceToken;
    static _Atomic int loadCount = 0;
    int n = atomic_fetch_add(&loadCount, 1) + 1;
    NSLog(@"[BubbleDeck] === DYLIB LOADED (第 %d 次) ===", n);

    @try {
        @autoreleasepool {
            dispatch_once(&onceToken, ^{
                NSLog(@"[BubbleDeck] entering constructor");
                [TDBubbleEntry install];
                NSLog(@"[BubbleDeck] install done");
            });
        }
    } @catch (NSException *e) {
        NSLog(@"[BubbleDeck] ✗ CONSTRUCTOR EXCEPTION: %@ - %@\n%@", e.name, e.reason, e.callStackSymbols);
    }
}
