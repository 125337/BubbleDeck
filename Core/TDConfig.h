//
//  TDConfig.h
//  BubbleDeck
//
//  配置与路径中心。目录形态（与 ThemeDeck v2 同款：目录即发行形态，零解包）：
//    Documents/BubbleDeck/packs/<气泡包名>/
//      ├── info.json   ★（type = bubble）
//      ├── Assets/     ★（ChatRoom_Bubble_*.png）
//      └── icon.png
//

#import <Foundation/Foundation.h>

/// 插件版本（与 control 的 Version 保持同步）
extern NSString * const kTDVersion;

@interface TDConfig : NSObject

/// 当前激活气泡包名（prefs.plist: activePack，对应 packs 下的目录名）
+ (nullable NSString *)activePack;

+ (void)setActivePack:(nullable NSString *)name;

/// 激活气泡包的包根目录（未激活或目录不存在返回 nil）
+ (nullable NSString *)activePackDir;

/// packs 目录（Documents/BubbleDeck/packs，不存在则创建）
+ (NSString *)packsRoot;

/// 已安装的气泡包名列表（packsRoot 下含 info.json 的目录名，按名称排序）
+ (NSArray<NSString *> *)availablePacks;

@end
