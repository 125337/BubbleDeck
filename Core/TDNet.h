//
//  TDNet.h
//  BubbleDeck
//
//  授权 API 网络层：纯 HTTPS + JSON POST（V4 客户端零秘密：无内置密钥、无请求签名）。
//  契约见 docs/授权系统方案.md：
//    响应 { "code": 0, "msg": "ok", "data": {...} }
//    防护在服务器侧：限频 + 卡密熵 + wxid 绑定业务逻辑
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
