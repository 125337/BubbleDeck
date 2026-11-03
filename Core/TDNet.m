//
//  TDNet.m
//  BubbleDeck
//
//  同步实现（NSURLConnection sendSynchronousRequest，15s 超时）+ 异步包装。
//  签名：HMAC-SHA256(SALT, "{ts毫秒}|{body原始字节}")。SALT 内置（V1 妥协，见方案）。
//

#import "TDNet.h"
#import "TDLog.h"
#import <CommonCrypto/CommonCrypto.h>
#import <string.h>

static NSString * const kBDAPIBase = @"https://qb.xhhan.xyz/bd/";
static NSString * const kBDSalt    = @"1012974b0777eac9c3e2dc96c2e725557e847c2f631f1a26";

@implementation TDNet

// ────── 工具 ──────

static NSString *BDHex(NSData *d) {
    const uint8_t *b = (const uint8_t *)d.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSData *BDHMACSHA256(NSData *data) {
    const char *key = kBDSalt.UTF8String;
    NSMutableData *mac = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, key, strlen(key), data.bytes, data.length, mac.mutableBytes);
    return mac;
}

// ────── 核心（同步） ──────

+ (nullable NSDictionary *)syncPostPath:(NSString *)path body:(nullable NSDictionary *)body {
    NSData *json = [NSJSONSerialization dataWithJSONObject:(body ?: @{}) options:0 error:nil];
    if (!json) return nil;

    NSString *ts = [NSString stringWithFormat:@"%lld",
                    (long long)([[NSDate date] timeIntervalSince1970] * 1000.0)];
    NSMutableData *signSrc = [NSMutableData dataWithCapacity:ts.length + 1 + json.length];
    [signSrc appendData:[[ts stringByAppendingString:@"|"] dataUsingEncoding:NSUTF8StringEncoding]];
    [signSrc appendData:json];

    NSString *url = [kBDAPIBase stringByAppendingString:path];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:ts forHTTPHeaderField:@"X-BD-Ts"];
    [req setValue:BDHex(BDHMACSHA256(signSrc)) forHTTPHeaderField:@"X-BD-Sign"];

    NSURLResponse *resp = nil;
    NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    if (!data) {
        TDLogD(@"NET", @"[TDNet] %@ 网络失败: %@", path, err.localizedDescription);
        return nil;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        TDLogD(@"NET", @"[TDNet] %@ 响应非 JSON", path);
        return nil;
    }
    return obj;
}

+ (void)postPath:(NSString *)path
            body:(nullable NSDictionary *)body
      completion:(void (^)(NSInteger code, NSString *msg, NSDictionary *data))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *resp = [self syncPostPath:path body:body];
        NSInteger code = resp ? [resp[@"code"] integerValue] : -1;
        NSString *msg = resp ? (resp[@"msg"] ?: @"") : @"网络异常";
        NSDictionary *data = [resp[@"data"] isKindOfClass:[NSDictionary class]] ? resp[@"data"] : @{};
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(code, msg, data);
        });
    });
}

// ────── 错误码人话 ──────

+ (NSString *)humanMessageForCode:(NSInteger)code serverMsg:(nullable NSString *)msg {
    switch (code) {
        case 0:    return @"ok";
        case 1001: return @"卡密不存在，请检查输入";
        case 1002: return @"卡密已停用，请联系卖家";
        case 1004: return @"参数缺失";
        case 1005: return @"此码已绑定其他微信号，请重新购买";
        case 3001: return @"气泡包不存在或已下架";
        case 4001:
        case 4002:
        case 4003: return @"请求校验失败，请检查设备时间";
        case -1:   return @"网络异常，请稍后再试";
        default:   return msg.length ? msg : @"操作失败";
    }
}

@end
