//
//  TDZip.h
//  BubbleDeck
//
//  .bdpack 容器解密 + 解压落盘。
//  容器格式（tools/pack.py 打包端）：
//    [0..3]  "BDPK" 魔数
//    [4]     版本号（=1）
//    [5..20] 随机 IV（16B）
//    [21..]  AES-256-CBC(PKCS7, 内含标准 zip)
//  解密得标准 zip → 纯 libz 解析落盘（ThemeDeck v1 解析器回归，零第三方依赖）。
//

#import <Foundation/Foundation.h>

@interface TDZip : NSObject

/// 数据 md5 校验（大小写不敏感）
+ (BOOL)verifyMd5:(NSString *)md5 ofData:(NSData *)data;

/// 解密 .bdpack 并解压到 packs/<packName>/（覆盖旧版本）
/// key = 授权清单随 owned 包下发的 32 字符密钥；失败 *error 带人话描述
+ (BOOL)installBdpackData:(NSData *)blob
                      key:(NSString *)key
                 packName:(NSString *)packName
                    error:(NSError **)error;

@end
