//
//  TDLog.m
//  BubbleDeck
//

#import "TDLog.h"

static NSString *BDPrefsPath(void) {
    NSString *prefs = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES)
                       firstObject];
    prefs = [prefs stringByAppendingPathComponent:@"Preferences/BubbleDeck"];
    [[NSFileManager defaultManager] createDirectoryAtPath:prefs withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return [prefs stringByAppendingPathComponent:@"prefs.plist"];
}

@implementation _TDLogManager {
    dispatch_queue_t _queue;
    NSString *_path;
}

+ (instancetype)shared {
    static _TDLogManager *mgr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mgr = [_TDLogManager new];
        mgr->_queue = dispatch_queue_create("com.bubbledeck.log", DISPATCH_QUEUE_SERIAL);
        NSString *dir = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
                          firstObject] stringByAppendingPathComponent:@"BubbleDeck_Logs"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                                   attributes:nil error:nil];
        mgr->_path = [dir stringByAppendingPathComponent:@"BubbleDeck.log"];
    });
    return mgr;
}

+ (BOOL)fileLoggingEnabled {
    NSNumber *v = [NSMutableDictionary dictionaryWithContentsOfFile:BDPrefsPath()][@"fileLog"];
    return v ? v.boolValue : YES; // 默认开
}

+ (void)setFileLoggingEnabled:(BOOL)on {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:BDPrefsPath()]
        ?: [NSMutableDictionary dictionary];
    d[@"fileLog"] = @(on);
    [d writeToFile:BDPrefsPath() atomically:YES];
}

+ (void)appendLineWithTag:(NSString *)tag content:(NSString *)line {
    [[self shared] append:tag line:line];
}

- (void)append:(NSString *)tag line:(NSString *)line {
    if (![[_TDLogManager class] fileLoggingEnabled]) return; // 运行时开关
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    NSString *out = [NSString stringWithFormat:@"[%@][%@] %@\n",
                     [fmt stringFromDate:[NSDate date]], tag ?: @"-", line ?: @""];
    dispatch_async(_queue, ^{
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:self->_path];
        if (!fh) {
            [out writeToFile:self->_path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    });
}

@end
