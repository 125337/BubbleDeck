//
//  TDLog.h
//  BubbleDeck
//
//  统一日志：控制台 + 文件（Documents/BubbleDeck_Logs/BubbleDeck.log）。
//  用法:
//    TDLog(@"ALT",  @"命中气泡 %@ -> %@", name, path);   // 控制台 + 文件
//    TDLogD(@"DEV", @"...");                              // 仅文件
//  文件写入支持运行时开关（设置页日志开关，默认开）。
//

#import <Foundation/Foundation.h>

#define TD_LOG_SILENT 0

// 按值判断（不是 #ifdef）：定义为 0 时日志正常编译
#if TD_LOG_SILENT

#define TDLog(tag, fmt, ...)   do {} while(0)
#define TDLogD(tag, fmt, ...)  do {} while(0)

#else

#define TDLog(tag, fmt, ...) \
    do { \
        NSString *_msg = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
        NSLog(@"[BD][%@] %@", (tag), _msg); \
        [_TDLogManager appendLineWithTag:(tag) content:_msg]; \
    } while(0)

#define TDLogD(tag, fmt, ...) \
    do { \
        NSString *_msg = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
        [_TDLogManager appendLineWithTag:(tag) content:_msg]; \
    } while(0)

#endif // TD_LOG_SILENT

@interface _TDLogManager : NSObject
+ (void)appendLineWithTag:(NSString *)tag content:(NSString *)line;
/// 文件日志开关（持久化到 BubbleDeck prefs，默认开；控制台 NSLog 不受影响）
+ (BOOL)fileLoggingEnabled;
+ (void)setFileLoggingEnabled:(BOOL)on;
@end
