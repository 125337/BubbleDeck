//
//  TDZip.m
//  BubbleDeck
//
//  zip 解析部分取自 ThemeDeck v1 Engine/TDPackLoader.m（commit 9f9b1b0）：
//  EOCD → central directory → local header → stored/deflate，纯 libz raw inflate。
//

#import "TDZip.h"
#import "TDPackLoader.h"
#import "../Core/TDLog.h"
#import <CommonCrypto/CommonCrypto.h>
#import <string.h>
#import <zlib.h>

@implementation TDZip

// ────── 错误 ──────

static BOOL BDFail(NSError **error, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (error) {
        *error = [NSError errorWithDomain:@"BubbleDeck.TDZip" code:-1
                                  userInfo:@{ NSLocalizedDescriptionKey : msg }];
    }
    TDLog(@"LIC", @"[TDZip] %@", msg);
    return NO;
}

// ────── md5 ──────

static NSString *BDMD5Hex(NSData *data) {
    unsigned char dig[CC_MD5_DIGEST_LENGTH];
    CC_MD5(data.bytes, (CC_LONG)data.length, dig);
    NSMutableString *s = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [s appendFormat:@"%02x", dig[i]];
    return s;
}

+ (BOOL)verifyMd5:(NSString *)md5 ofData:(NSData *)data {
    return [[BDMD5Hex(data) lowercaseString] isEqualToString:(md5.lowercaseString ?: @"")];
}

// ────── zip 解析（ThemeDeck v1） ──────

static uint16_t RD16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t RD32(const uint8_t *p) { return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24)); }

// raw deflate 解压（hint 为 central directory 里的 uncompressed size，可为 0）
static NSData *TDInflateRaw(const uint8_t *src, uLong srcLen, uLong hint) {
    size_t cap = hint > 0 ? hint : 65536;
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, -MAX_WBITS) != Z_OK) return nil;
    zs.next_in = (Bytef *)src;
    zs.avail_in = (uInt)srcLen;
    uLong total = 0;
    int ret;
    do {
        if (total == out.length) [out increaseLengthBy:cap];
        zs.next_out = (Bytef *)out.mutableBytes + total;
        zs.avail_out = (uInt)(out.length - total);
        ret = inflate(&zs, Z_NO_FLUSH);
        if (ret != Z_OK && ret != Z_STREAM_END) { inflateEnd(&zs); return nil; }
        total = zs.total_out;
    } while (ret != Z_STREAM_END);
    inflateEnd(&zs);
    out.length = total;
    return out;
}

// 路径安全：拒绝绝对路径与 .. 上跳
static BOOL TDSafeRelPath(NSString *rel) {
    if ([rel hasPrefix:@"/"] || [rel hasPrefix:@"\\"]) return NO;
    for (NSString *c in [rel pathComponents]) {
        if ([c isEqualToString:@".."]) return NO;
    }
    return YES;
}

// 解压 zipData 到 destDir；成功返回 YES
static BOOL TDUnzip(NSData *zipData, NSString *destDir) {
    const uint8_t *b = (const uint8_t *)zipData.bytes;
    const NSUInteger len = zipData.length;
    if (len < 22) return NO;

    // 1. 找 EOCD（从尾部向前搜签名 0x06054b50，注释区最多 64KB）
    NSUInteger eocd = NSNotFound;
    NSUInteger floor = len > 22 + 65557 ? len - 22 - 65557 : 0;
    for (NSUInteger i = len - 22 + 1; i-- > floor;) {
        if (RD32(b + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd == NSNotFound) return NO;

    uint16_t entryCount = RD16(b + eocd + 10);
    uint32_t cdOffset   = RD32(b + eocd + 16);

    NSFileManager *fm = [NSFileManager defaultManager];

    // 2. 遍历 central directory（签名 0x02014b50）
    const uint8_t *p = b + cdOffset;
    for (uint16_t n = 0; n < entryCount; n++) {
        if ((NSUInteger)(p - b) + 46 > len) return NO;
        if (RD32(p) != 0x02014b50) return NO;

        uint16_t method      = RD16(p + 10);
        uint32_t compSize    = RD32(p + 20);
        uint32_t uncompSize  = RD32(p + 24);
        uint16_t nameLen     = RD16(p + 28);
        uint16_t extraLen    = RD16(p + 30);
        uint16_t commentLen  = RD16(p + 32);
        uint32_t localOffset = RD32(p + 42);

        // 名称解码：UTF-8 优先，GBK（Windows 资源管理器）容错，Latin1 兜底
        NSString *name = [[NSString alloc] initWithBytes:p + 46 length:nameLen encoding:NSUTF8StringEncoding];
        if (!name.length) {
            name = [[NSString alloc] initWithBytes:p + 46 length:nameLen
                    encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
        }
        if (!name.length) {
            name = [[NSString alloc] initWithBytes:p + 46 length:nameLen
                    encoding:NSISOLatin1StringEncoding];
        }
        p += 46 + nameLen + extraLen + commentLen;
        if (!name.length) return NO;
        if (!TDSafeRelPath(name)) continue;

        BOOL isDir = [name hasSuffix:@"/"];

        // 3. local header：取其自身的 name/extra 长度定位数据区（0x04034b50）
        if (localOffset + 30 > len) return NO;
        const uint8_t *lh = b + localOffset;
        if (RD32(lh) != 0x04034b50) return NO;
        uint16_t lhNameLen  = RD16(lh + 26);
        uint16_t lhExtraLen = RD16(lh + 28);
        const uint8_t *data = lh + 30 + lhNameLen + lhExtraLen;
        if ((NSUInteger)(data - b) + compSize > len) return NO;

        NSString *dest = [destDir stringByAppendingPathComponent:name];

        if (isDir) {
            [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
            continue;
        }
        [fm createDirectoryAtPath:[dest stringByDeletingLastPathComponent]
                      withIntermediateDirectories:YES attributes:nil error:nil];

        NSData *content = nil;
        if (method == 0) {
            content = [NSData dataWithBytes:data length:compSize];
        } else if (method == 8) {
            content = TDInflateRaw(data, compSize, uncompSize);
        }
        if (!content) { TDLogD(@"LIC", @"[TDZip] 条目解压失败: %@", name); return NO; }
        if (![content writeToFile:dest atomically:YES]) { TDLogD(@"LIC", @"[TDZip] 写文件失败: %@", dest); return NO; }
    }
    return YES;
}

// 包根定位：解包层本身有 info.json → 直接用；唯一子目录里有 info.json → 内容上提一层
static BOOL TDLocatePackRoot(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"info.json"]]) return YES;

    NSArray<NSString *> *subs = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSString *wrapper = nil;
    NSUInteger dirCount = 0;
    for (NSString *s in subs) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:s] isDirectory:&isDir] && isDir) {
            wrapper = s;
            dirCount++;
        }
    }
    if (dirCount == 1 && wrapper &&
        [fm fileExistsAtPath:[[dir stringByAppendingPathComponent:wrapper]
                              stringByAppendingPathComponent:@"info.json"]]) {
        NSString *w = [dir stringByAppendingPathComponent:wrapper];
        for (NSString *c in [fm contentsOfDirectoryAtPath:w error:nil]) {
            [fm moveItemAtPath:[w stringByAppendingPathComponent:c]
                        toPath:[dir stringByAppendingPathComponent:c] error:nil];
        }
        [fm removeItemAtPath:w error:nil];
    }
    return [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"info.json"]];
}

// ────── 主流程 ──────

+ (BOOL)installBdpackData:(NSData *)blob
                      key:(NSString *)key
                 packName:(NSString *)packName
                    error:(NSError **)error {
    if (!packName.length || [packName containsString:@"/"]) {
        return BDFail(error, @"包名非法: %@", packName);
    }
    if (!key.length || strlen(key.UTF8String) != kCCKeySizeAES256) {
        return BDFail(error, @"密钥非法（长度非 32）");
    }
    if (blob.length < 21 + kCCBlockSizeAES128 || memcmp(blob.bytes, "BDPK", 4) != 0) {
        return BDFail(error, @"不是有效的 .bdpack 文件");
    }
    const uint8_t *b = (const uint8_t *)blob.bytes;
    if (b[4] != 1) {
        return BDFail(error, @"容器版本不支持（v%u）", b[4]);
    }

    // 1. AES-256-CBC 解密（PKCS7，教科技书用法）
    NSData *iv = [blob subdataWithRange:NSMakeRange(5, 16)];
    NSData *ct = [blob subdataWithRange:NSMakeRange(21, blob.length - 21)];
    NSMutableData *pt = [NSMutableData dataWithLength:ct.length + kCCBlockSizeAES128];
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                 key.UTF8String, kCCKeySizeAES256, iv.bytes,
                                 ct.bytes, ct.length,
                                 pt.mutableBytes, pt.length, &moved);
    if (st != kCCSuccess) {
        return BDFail(error, @"解密失败（密钥不符或文件损坏: %d）", (int)st);
    }
    pt.length = moved;
    TDLogD(@"LIC", @"[TDZip] 解密完成: %@ 内层 zip %tu 字节", packName, pt.length);

    // 2. 解压到临时目录 → 定位包根 → 搬进 packs/<name>
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *temp = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSString stringWithFormat:@"BubbleDeck_install_%@_%@",
                                        packName, [NSUUID UUID].UUIDString]];
    [fm removeItemAtPath:temp error:nil];
    [fm createDirectoryAtPath:[temp stringByDeletingLastPathComponent]
          withIntermediateDirectories:YES attributes:nil error:nil];

    if (!TDUnzip(pt, temp)) {
        [fm removeItemAtPath:temp error:nil];
        return BDFail(error, @"解压失败（zip 结构异常）");
    }
    if (!TDLocatePackRoot(temp)) {
        [fm removeItemAtPath:temp error:nil];
        return BDFail(error, @"包内容缺少 info.json");
    }

    NSString *dest = [[[TDPackLoader packsRoot] stringByAppendingPathComponent:packName] copy];
    [fm removeItemAtPath:dest error:nil];   // 覆盖旧版本
    if (![fm moveItemAtPath:temp toPath:dest error:nil]) {
        [fm removeItemAtPath:temp error:nil];
        return BDFail(error, @"安装落盘失败");
    }
    TDLog(@"LIC", @"[TDZip] 安装完成: packs/%@", packName);
    return YES;
}

@end
