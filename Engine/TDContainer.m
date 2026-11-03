//
//  TDContainer.m
//  BubbleDeck
//
//  zip 解析原语取自 v0.5.0 Engine/TDZip.m（commit 遗产）：EOCD → central directory
//  → local header → stored/deflate，纯 libz raw inflate。V3 起索引逻辑归本类，
//  TDZip 只保留 md5 校验。
//

#import "TDContainer.h"
#import "TDPackLoader.h"
#import "../Core/TDConfig.h"
#import "../Core/TDLog.h"
#import "../Core/TDLicense.h"
#import <CommonCrypto/CommonCrypto.h>
#import <string.h>
#import <zlib.h>
#import <UIKit/UIKit.h>

// GCM oneshot 接口在 libcommonCrypto.dylib（iOS 9+），theos SDK 不带 CommonCryptorSPI.h，
// 显式声明原型（CCModeOptions 实际为 uint32_t）；符号注入时动态解析
extern CCCryptorStatus CCCryptorGCMOneshotDecrypt(uint32_t alg, uint32_t options,
                                                  const void *key, size_t keyLength,
                                                  const void *iv, size_t ivLen,
                                                  const void *aData, size_t aDataLength,
                                                  const void *dataIn, size_t dataInLength,
                                                  void *dataOut, size_t dataOutLength, size_t *dataOutMoved,
                                                  const void *tag, size_t tagLength);

// ────── zip 解析原语（TDZip 遗产平移） ──────

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

// central directory 条目（local header 的 name/extra 长度打开时重读）
typedef struct {
    uint32_t off;        // local header 偏移
    uint32_t csz;        // 压缩后大小
    uint32_t usz;        // 原始大小
    uint16_t method;     // 0 stored / 8 deflate
    uint16_t lhn;        // local header name 长度
    uint16_t lhx;        // local header extra 长度
} BDZEntry;

@interface TDContainer ()
@property (nonatomic, strong) NSData *zip;                       // 解密后的内层 zip
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *entries;  // 条目名 → BDZEntry
@end

@implementation TDContainer

// ────── 错误 ──────

static BOOL BDFail(NSError **error, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    if (error) {
        *error = [NSError errorWithDomain:@"BubbleDeck.TDContainer" code:-1
                                  userInfo:@{ NSLocalizedDescriptionKey : msg }];
    }
    TDLog(@"LIC", @"[TDContainer] %@", msg);
    return NO;
}

// ────── 解密（按魔数分版本） ──────
// v2：key = base64(32B)，AES-256-GCM，AAD 绑包名版本，tag 在密文体末尾
// v1：key = 32 字符原文，AES-256-CBC(PKCS7)
// 返回内层 zip 明文，失败 nil

static NSData *BDDecryptBlob(NSData *blob, NSString *key,
                             NSString *packName, NSString *version, NSError **error) {
    const uint8_t *b = (const uint8_t *)blob.bytes;
    const NSUInteger len = blob.length;

    if (len >= 4 && memcmp(b, "BDP2", 4) == 0) {
        if (len < 17 + 16 || b[4] != 2) {
            BDFail(error, @"容器版本不支持（v%u）", b[4]);
            return nil;
        }
        NSData *keyData = [[NSData alloc] initWithBase64EncodedString:key options:0];
        if (keyData.length != kCCKeySizeAES256) {
            BDFail(error, @"密钥格式非法（请联网刷新授权）");
            return nil;
        }

        NSData *iv  = [blob subdataWithRange:NSMakeRange(5, 12)];
        NSData *ct  = [blob subdataWithRange:NSMakeRange(17, len - 17 - 16)];
        NSData *tag = [blob subdataWithRange:NSMakeRange(len - 16, 16)];
        NSMutableData *pt = [NSMutableData dataWithLength:ct.length];
        NSString *aad = [NSString stringWithFormat:@"bdpack2|%@|%@", packName, version];
        size_t moved = 0;
        CCCryptorStatus st = CCCryptorGCMOneshotDecrypt(kCCAlgorithmAES128, 0,
                                                        keyData.bytes, keyData.length,
                                                        iv.bytes, iv.length,
                                                        aad.UTF8String, aad.length,
                                                        ct.bytes, ct.length,
                                                        pt.mutableBytes, pt.length, &moved,
                                                        (void *)tag.bytes, tag.length);
        if (st != kCCSuccess) {
            BDFail(error, @"解密失败（密钥不符或文件被篡改: %d）", (int)st);
            return nil;
        }
        TDLogD(@"LIC", @"[TDContainer] BDP2 解密成功: %@ 内层 zip %tu 字节", packName, pt.length);
        return pt;
    }

    if (len >= 4 && memcmp(b, "BDPK", 4) == 0) {
        if (len < 21 + kCCBlockSizeAES128 || b[4] != 1) {
            BDFail(error, @"容器版本不支持（v%u）", len >= 5 ? b[4] : 0);
            return nil;
        }
        if (key.length != 32) {
            BDFail(error, @"密钥非法（长度非 32）");
            return nil;
        }
        NSData *iv = [blob subdataWithRange:NSMakeRange(5, 16)];
        NSData *ct = [blob subdataWithRange:NSMakeRange(21, len - 21)];
        NSMutableData *pt = [NSMutableData dataWithLength:ct.length + kCCBlockSizeAES128];
        size_t moved = 0;
        CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding,
                                     key.UTF8String, kCCKeySizeAES256, iv.bytes,
                                     ct.bytes, ct.length,
                                     pt.mutableBytes, pt.length, &moved);
        if (st != kCCSuccess) {
            BDFail(error, @"解密失败（密钥不符或文件损坏: %d）", (int)st);
            return nil;
        }
        pt.length = moved;
        TDLogD(@"LIC", @"[TDContainer] BDPK(v1) 解密成功: %@ 内层 zip %tu 字节", packName, pt.length);
        return pt;
    }

    BDFail(error, @"不是有效的 .bdpack 文件");
    return nil;
}

// ────── 索引 ──────

// 路径安全：拒绝绝对路径与 .. 上跳
static BOOL TDSafeRelPath(NSString *rel) {
    if ([rel hasPrefix:@"/"] || [rel hasPrefix:@"\\"]) return NO;
    for (NSString *c in [rel pathComponents]) {
        if ([c isEqualToString:@".."]) return NO;
    }
    return YES;
}

// 条目名解码：UTF-8 优先，GBK（Windows 资源管理器）容错，Latin1 兜底
static NSString *BDEntryName(const uint8_t *p, uint16_t nameLen) {
    NSString *name = [[NSString alloc] initWithBytes:p length:nameLen encoding:NSUTF8StringEncoding];
    if (!name.length) {
        name = [[NSString alloc] initWithBytes:p length:nameLen
                encoding:CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000)];
    }
    if (!name.length) {
        name = [[NSString alloc] initWithBytes:p length:nameLen
                encoding:NSISOLatin1StringEncoding];
    }
    return name;
}

// 建索引；兼容打包时多套一层目录的包（唯一子目录里有 info.json → 内容名上提一层）
- (BOOL)buildIndex:(NSError **)error {
    const uint8_t *b = (const uint8_t *)self.zip.bytes;
    const NSUInteger len = self.zip.length;
    if (len < 22) return BDFail(error, @"内层 zip 结构异常");

    NSUInteger eocd = NSNotFound;
    NSUInteger floor = len > 22 + 65557 ? len - 22 - 65557 : 0;
    for (NSUInteger i = len - 22 + 1; i-- > floor;) {
        if (RD32(b + i) == 0x06054b50) { eocd = i; break; }
    }
    if (eocd == NSNotFound) return BDFail(error, @"内层 zip 结构异常");

    uint16_t entryCount = RD16(b + eocd + 10);
    uint32_t cdOffset   = RD32(b + eocd + 16);

    NSMutableDictionary<NSString *, NSValue *> *raw = [NSMutableDictionary dictionary];
    const uint8_t *p = b + cdOffset;
    for (uint16_t n = 0; n < entryCount; n++) {
        if ((NSUInteger)(p - b) + 46 > len) return BDFail(error, @"内层 zip 结构异常");
        if (RD32(p) != 0x02014b50) return BDFail(error, @"内层 zip 结构异常");

        BDZEntry e;
        e.method = RD16(p + 10);
        e.csz    = RD32(p + 20);
        e.usz    = RD32(p + 24);
        uint16_t nameLen    = RD16(p + 28);
        uint16_t extraLen   = RD16(p + 30);
        uint16_t commentLen = RD16(p + 32);
        e.off = RD32(p + 42);

        NSString *name = BDEntryName(p + 46, nameLen);
        p += 46 + nameLen + extraLen + commentLen;
        if (!name.length || [name hasSuffix:@"/"] || !TDSafeRelPath(name)) continue;

        // local header 自身 name/extra 长度（数据区定位）
        if (e.off + 30 > len) return BDFail(error, @"内层 zip 结构异常");
        const uint8_t *lh = b + e.off;
        if (RD32(lh) != 0x04034b50) return BDFail(error, @"内层 zip 结构异常");
        e.lhn = RD16(lh + 26);
        e.lhx = RD16(lh + 28);

        raw[name] = [NSValue valueWithBytes:&e objCType:@encode(BDZEntry)];
    }
    if (!raw.count) return BDFail(error, @"包内容缺少 info.json");

    // 包根定位：根层有 info.json 直接用；否则唯一子目录里有 → 全部条目剥掉该前缀
    NSString *strip = nil;
    if (!raw[@"info.json"]) {
        for (NSString *n in raw) {
            if ([n hasSuffix:@"/info.json"]) {
                strip = [n substringToIndex:n.length - @"info.json".length];
                break;
            }
        }
    }

    self.entries = [NSMutableDictionary dictionary];
    for (NSString *n in raw) {
        NSString *key = strip && [n hasPrefix:strip] ? [n substringFromIndex:strip.length] : n;
        if (key.length) self.entries[key] = raw[n];
    }
    if (!self.entries[@"info.json"]) return BDFail(error, @"包内容缺少 info.json");
    return YES;
}

// ────── 共享缓存（每包解密一次；memory warning 全清） ──────

static NSMutableDictionary<NSString *, TDContainer *> *s_containers = nil;

static void BDSetupCache(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_containers = [NSMutableDictionary dictionary];
        [[NSNotificationCenter defaultCenter] addObserverForName:
            UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil
            usingBlock:^(__unused NSNotification *n) {
                @synchronized (s_containers) {
                    NSUInteger cnt = s_containers.count;
                    [s_containers removeAllObjects];
                    if (cnt) TDLogD(@"LIC", @"[TDContainer] memory warning 清空 %lu 个容器缓存", (unsigned long)cnt);
                }
            }];
    });
}

+ (nullable instancetype)cachedContainerForPack:(NSString *)packName error:(NSError **)error {
    if (!packName.length) { BDFail(error, @"包名为空"); return nil; }
    BDSetupCache();

    // 取图口有后台线程路径（分享/文件导入实测），NSMutableDictionary 非线程安全，全程加锁
    @synchronized (s_containers) {
        TDContainer *c = s_containers[packName];
        if (c) return c;

        NSString *dir = [TDPackLoader packDirForName:packName];
        if (!dir) { BDFail(error, @"包未安装: %@", packName); return nil; }

        NSData *blob = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"pack.bdpack"]];
        if (!blob) { BDFail(error, @"密文包文件缺失: %@", packName); return nil; }

        // 版本从明文 info.json 读（安装时落盘，与打包 AAD 同源）——JSON 格式，NSJSONSerialization 解析
        NSData *infoData = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"info.json"]];
        id info = infoData ? [NSJSONSerialization JSONObjectWithData:infoData options:0 error:nil] : nil;
        NSString *version = ([info isKindOfClass:[NSDictionary class]]
                             && [info[@"version"] isKindOfClass:[NSString class]]
                             && info[@"version"].length) ? info[@"version"] : @"1.0";

        NSString *key = [TDLicense keyForPack:packName];
        if (!key.length) { BDFail(error, @"缺少解密密钥（请联网刷新授权）"); return nil; }

        NSData *zip = BDDecryptBlob(blob, key, packName, version, error);
        if (!zip) return nil;

        c = [TDContainer new];
        c.zip = zip;
        if (![c buildIndex:error]) return nil;
        s_containers[packName] = c;
        return c;
    }
}

+ (void)purgeContainerForPack:(NSString *)packName {
    if (!s_containers) return;
    @synchronized (s_containers) {
        if (s_containers[packName]) {
            [s_containers removeObjectForKey:packName];
            TDLogD(@"LIC", @"[TDContainer] 清除容器缓存: %@", packName);
        }
    }
}

// ────── 取条目 ──────

- (BOOL)hasEntry:(NSString *)path {
    return path.length > 0 && self.entries[path] != nil;
}

- (nullable NSData *)dataForEntry:(NSString *)path {
    NSValue *v = self.entries[path];
    if (!v) return nil;
    BDZEntry e;
    [v getValue:&e];

    const uint8_t *b = (const uint8_t *)self.zip.bytes;
    const NSUInteger len = self.zip.length;
    const uint8_t *data = b + e.off + 30 + e.lhn + e.lhx;
    if ((NSUInteger)(data - b) + e.csz > len) return nil;

    if (e.method == 0) return [NSData dataWithBytes:data length:e.csz];
    if (e.method == 8) return TDInflateRaw(data, e.csz, e.usz);
    return nil;
}

- (NSInteger)imageCount {
    NSInteger files = 0;
    for (NSString *n in self.entries) {
        if (![n hasPrefix:@"Assets/"]) continue;
        NSString *ext = n.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
            [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"webp"]) files++;
    }
    return files;
}

// ────── 下载安装（零解压、零明文 PNG 落盘） ──────

+ (BOOL)installBdpackData:(NSData *)blob
                      key:(NSString *)key
                 packName:(NSString *)packName
                  version:(NSString *)version
                    error:(NSError **)error {
    if (!packName.length || [packName containsString:@"/"]) {
        return BDFail(error, @"包名非法: %@", packName);
    }

    // 1. 试解密（错 key / 篡改 / AAD 不符在此报错，人话透传 UI）
    NSData *zip = BDDecryptBlob(blob, key, packName, version ?: @"1.0", error);
    if (!zip) return NO;

    // 2. 建临时容器对象提取 info.json（不入共享缓存，避免装到一半占内存）
    TDContainer *tmp = [TDContainer new];
    tmp.zip = zip;
    if (![tmp buildIndex:error]) return NO;
    NSData *infoData = [tmp dataForEntry:@"info.json"];
    if (!infoData) return BDFail(error, @"包内容缺少 info.json");

    // 3. 密文原样落盘 + info.json 明文（TDPackLoader.availablePacks 只认它）
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dest = [[TDPackLoader packsRoot] stringByAppendingPathComponent:packName];
    [fm removeItemAtPath:dest error:nil];                       // 覆盖旧版本（含遗留明文目录）
    if (![fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil]) {
        return BDFail(error, @"安装落盘失败");
    }
    if (![blob writeToFile:[dest stringByAppendingPathComponent:@"pack.bdpack"] atomically:YES] ||
        ![infoData writeToFile:[dest stringByAppendingPathComponent:@"info.json"] atomically:YES]) {
        [fm removeItemAtPath:dest error:nil];
        return BDFail(error, @"安装落盘失败");
    }

    [self purgeContainerForPack:packName];
    [TDConfig setPackSource:packName source:@"online"];
    TDLog(@"LIC", @"[TDContainer] 安装完成（零解压）: packs/%@/pack.bdpack", packName);
    return YES;
}

@end
