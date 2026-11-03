//
//  TDZip.m
//  BubbleDeck
//
//  V3 起仅剩 md5 校验。原解密+解压安装逻辑迁 Engine/TDContainer.m
//  （zip 解析原语同源平移，见该文件头注释）。
//

#import "TDZip.h"
#import "../Core/TDLog.h"
#import <CommonCrypto/CommonCrypto.h>

@implementation TDZip

+ (BOOL)verifyMd5:(NSString *)md5 ofData:(NSData *)data {
    unsigned char dig[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, dig);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", dig[i]];
    return [[s lowercaseString] isEqualToString:(md5.lowercaseString ?: @"")];
}

@end
