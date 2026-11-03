//
//  TDLicense.h
//  BubbleDeck
//
//  V2 授权模型：插件免费壳，一包一码，wxid 绑定（契约见 docs/授权系统方案.md）。
//    激活  = 输码入账（activate），码的使命结束，客户端不存码
//    报到  = 每次启动 POST /packs，服务器下发 owned 清单 = 唯一真话来源
//    兜底  = 清单缓存 7 天，断网沿用；超期在线包全禁用（本地导入包不受限）
//  Keychain 只存 wxid 缓存 + 清单缓存 + 报到时间戳，敏感信息趋零。
//

#import <Foundation/Foundation.h>

/// 清单刷新完成通知（激活成功 / 启动报到后都会发，UI 收到重建）
FOUNDATION_EXPORT NSNotificationName const TDLicenseStateChangedNotification;

@interface TDLicense : NSObject

/// 启动报到：后台异步 POST /packs（wxid+IDFV）→ 缓存清单+时间戳 → 主线程发通知。
/// 网络失败静默沿用旧缓存。可重复调用。
+ (void)refreshEntitlements;

/// 同上，completion 主线程回调（成功失败都回，ok=清单是否刷新成功）。
+ (void)refreshEntitlementsWithCompletion:(void (^)(BOOL ok))completion;

/// 激活（设置页在线包行内输码）。wxid 抓不到直接本地拒绝（绑定主键就是 wxid）。
/// 成功后内部同步报到拉回新授权，completion 主线程回调；ok=NO 时 message 为人话错误。
+ (void)activateLicense:(NSString *)license
             completion:(void (^)(BOOL ok, NSString *message))completion;

// ── 清单缓存读取（全部内存缓存，闸门在取图热路径上，禁止 Keychain IO） ──

/// 缓存的 /packs 清单（结构同服务器 data.packs；从未报到成功返回 nil）
+ (nullable NSArray<NSDictionary *> *)entitlements;

/// 上次报到距今是否超 7 天（从未报到成功也算超期）
+ (BOOL)entitlementsExpired;

/// 在线包闸门：清单未超期 且 该包 owned=YES 才放行
+ (BOOL)gateOpenForPack:(NSString *)name;

/// 该包是否已拥有（基于缓存清单）
+ (BOOL)isOwnedPack:(NSString *)name;

/// owned 包的下载密钥（未拥有返回 nil）
+ (nullable NSString *)keyForPack:(NSString *)name;

// ── 网络请求参数 ──

/// wxid：CContactMgr 实时抓取，失败回落 Keychain 缓存；都没有返回 nil
+ (nullable NSString *)currentWxid;

/// 设备 ID（IDFV；异常时用 Keychain 持久 UUID 兜底）
+ (NSString *)deviceID;

/// 设备尾号（展示用，deviceID 后 4 位）
+ (NSString *)deviceTail;

@end
