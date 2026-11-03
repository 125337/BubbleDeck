//
//  TDZip.h
//  BubbleDeck
//
//  .bdpack 传输层校验。V3 起解密/索引/安装归 TDContainer（零解压、盘上常密），
//  本类只保留 md5 校验（传输完整性，内容完整性由 GCM tag 保证）。
//

#import <Foundation/Foundation.h>

@interface TDZip : NSObject

/// 数据 md5 校验（大小写不敏感）
+ (BOOL)verifyMd5:(NSString *)md5 ofData:(NSData *)data;

@end
