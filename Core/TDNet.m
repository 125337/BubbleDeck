//
//  TDNet.m
//  BubbleDeck
//
//  同步实现（NSURLConnection sendSynchronousRequest，15s 超时）+ 异步包装。
//  V4 客户端零秘密：dylib 内无任何密钥，不带签名头。防护全在服务器侧（限频等）。
//

#import "TDNet.h"
#import "TDLog.h"

static NSString * const kBDAPIBase = @"https://qb.xhhan.xyz/bd/";

@implementation TDNet

// ────── 核心（同步） ──────

+ (nullable NSDictionary *)syncPostPath:(NSString *)path body:(nullable NSDictionary *)body {
    NSData *json = [NSJSONSerialization dataWithJSONObject:(body ?: @{}) options:0 error:nil];
    if (!json) return nil;

    NSString *url = [kBDAPIBase stringByAppendingString:path];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = json;
    req.timeoutInterval = 15;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

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
        case 1007: return @"操作过于频繁，请一小时后再试";
        case 429:  return @"请求过于频繁，请稍后再试";
        case 3001: return @"气泡包不存在或已下架";
        case -1:   return @"网络异常，请稍后再试";
        default:   return msg.length ? msg : @"操作失败";
    }
}

@end
