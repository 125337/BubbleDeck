//
//  TDPackLoader.h
//  BubbleDeck
//
//  包加载（目录即发行形态，无 zip）：
//    Documents/BubbleDeck/packs/<气泡包名>/
//      ├── info.json   ★（type = bubble）
//      ├── Assets/     ★（ChatRoom_Bubble_*.png）
//      └── icon.png    ★
//  气泡包由 PC 侧制作目录，整体拷入 packs 即用。
//

#import <Foundation/Foundation.h>

@interface TDPackLoader : NSObject

/// packs 目录（Documents/BubbleDeck/packs，不存在则创建，放气泡包文件夹）
+ (NSString *)packsRoot;

/// 已安装气泡包名列表（packsRoot 下含 info.json 的目录名，排序）
+ (NSArray<NSString *> *)availablePacks;

/// 气泡包目录（目录存在即返回，不校验内容；不存在返回 nil）
+ (nullable NSString *)packDirForName:(NSString *)name;

@end
