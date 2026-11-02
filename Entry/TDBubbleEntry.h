//
//  TDBubbleEntry.h
//  BubbleDeck
//
//  注入总入口：气泡引擎 hook + 微信"第三方插件"页设置页注册
//  （WCPluginsMgr.sharedInstance + registerControllerWithTitle:version:controller:，
//  机制与 ThemeDeck/MioPlugin 同款）。
//

#import <Foundation/Foundation.h>

@interface TDBubbleEntry : NSObject
+ (void)install;
@end
