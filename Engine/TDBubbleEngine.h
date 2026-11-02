//
//  TDBubbleEngine.h
//  BubbleDeck
//
//  聊天气泡供给引擎：hook MMThemeManager 位图双入口，按请求名在激活气泡包里查图。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface TDBubbleEngine : NSObject

+ (void)installHooks;

/// 气泡包缓存清理（切换气泡包后必调，否则负缓存错误放行）
+ (void)purgeCaches;

/// 包内查气泡图（miss 返回 nil，由调用方放行原实现）
+ (nullable UIImage *)bubbleImageForName:(nullable NSString *)name;

@end
