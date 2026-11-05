//
//  TDContainer.h
//  BubbleDeck
//
//  V3 包加密容器（盘上常密、内存惰性解密，对齐 ThemePro 工作束方案）。
//  容器格式（tools/pack.py 打包端）：
//    [0..3]  "BDP2" 魔数
//    [4]     容器版本（=2）
//    [5..16] 随机 IV（GCM nonce，12B）
//    [17..]  AES-256-GCM(内含标准 zip) + tag(16B，密文体末尾)
//    AAD     = "bdpack2|<包名>|<版本>"（防篡改/拼接/跨包挪用；tag 自带完整性）
//  兼容 v1 容器：[0..3]"BDPK" [4]=1 [5..20]IV(16B) AES-256-CBC(PKCS7)，key 为 32 字符原文。
//

#import <Foundation/Foundation.h>

@interface TDContainer : NSObject

/// 已安装包的共享容器：读 packs/<名>/pack.bdpack + info.json 版本 + 清单下发的 key，
/// 整包解密一次后常驻缓存（2-5MB），memory warning 全清。失败 *error 带人话描述。
+ (nullable instancetype)cachedContainerForPack:(NSString *)packName error:(NSError **)error;

/// 下载安装（零解压零明文落盘）：md5 已验 → 试解密校验（错 key/文件坏在此报错）
/// → 密文原样写 packs/<名>/pack.bdpack + info.json 明文落盘 → 标记 source=online。
/// 覆盖旧版本；key/ver 与服务器 keys 表对应（v2=base64 32B，v1=32 字符原文）。
+ (BOOL)installBdpackData:(NSData *)blob
                      key:(NSString *)key
                 packName:(NSString *)packName
                  version:(NSString *)version
                    error:(NSError **)error;

/// 单包缓存清除（重装新版本后调用）
+ (void)purgeContainerForPack:(NSString *)packName;

/// 条目是否存在 / 取条目数据（stored 直取、deflate 按需 inflate）
- (BOOL)hasEntry:(NSString *)path;
- (nullable NSData *)dataForEntry:(NSString *)path;

@end
