//
//  TDLicense.h
//  BubbleDeck
//
//  V4 现取形态：key 不落盘，每次冷启动/进商店页现取（POST /packs），仅内存持有。
//    激活  = 输码入账（activate），码的使命结束，客户端不存码
//    报到  = 启动/商店页 POST /packs，服务器下发 owned 清单（含 key）= 唯一真话来源
//    兜底  = 无。断网 = 本进程内沿用内存清单；重启后必须联网现取（封卡/换 key 即时生效）
//  Keychain 只存 wxid 缓存 + 设备兜底 UUID；清单与 key 绝不落盘（砸壳/备份只有密文）。
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

// ── 清单读取（仅内存，闸门在取图热路径上；本进程未报到成功 = 全禁） ──

/// 本进程内缓存的 /packs 清单（结构同服务器 data.packs；未报到成功返回 nil）
+ (nullable NSArray<NSDictionary *> *)entitlements;

/// 本进程是否从未报到成功（未联网现取 → 在线包全禁用）
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
