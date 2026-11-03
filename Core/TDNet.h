//
//  TDNet.h
//  BubbleDeck
//
//  授权 API 网络层：统一 HMAC 签名 + JSON POST。
//  契约见 docs/授权系统方案.md：
//    请求头 X-BD-Ts（毫秒时间戳）
//    请求头 X-BD-Sign = HMAC-SHA256(SALT, "{ts}|{body}")，服务端校验 ±300s
//    响应 { "code": 0, "msg": "ok", "data": {...} }
//

#import <Foundation/Foundation.h>

@interface TDNet : NSObject

/// 同步 POST（禁止主线程调用）。返回完整响应字典；网络失败返回 nil。
+ (nullable NSDictionary *)syncPostPath:(NSString *)path body:(nullable NSDictionary *)body;

/// 异步 POST（后台队列请求，主线程回调）。code=-1 表示网络失败。
+ (void)postPath:(NSString *)path
            body:(nullable NSDictionary *)body
      completion:(void (^)(NSInteger code, NSString *msg, NSDictionary *data))completion;

/// 错误码转人话（UI 弹窗用）
+ (NSString *)humanMessageForCode:(NSInteger)code serverMsg:(nullable NSString *)msg;

@end
