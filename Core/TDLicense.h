//
//  TDLicense.h
//  BubbleDeck
//
//  授权状态机：Keychain 存 token/卡密/最近报到时间。
//    未激活        → 收费闸门全放行官方图，设置页显示激活入口
//    激活有效      → verify 报到成功 / 7 天兜底期内
//    兜底超期      → 断网超 7 天，等同未激活
//  token 失效(2001) → 用 Keychain 卡密自动重激活（无感）
//

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, TDLicenseState) {
    TDLicenseStateNotActivated = 0,
    TDLicenseStateActive,
    TDLicenseStateGraceExpired,
};

/// 状态变更通知（object = @(TDLicenseState)）
FOUNDATION_EXPORT NSNotificationName const TDLicenseStateChangedNotification;

@interface TDLicense : NSObject

/// 收费闸门专用：纯内存 BOOL（hook 热路径零开销）。启动即从 Keychain 恢复，之后由 startupCheck 更新。
+ (BOOL)isActiveNow;

/// 当前状态（同步，首次调用从 Keychain 恢复）
+ (TDLicenseState)state;

/// 启动自愈：后台异步 verify → 过期自动重激活 → 更新内存状态 + 发通知。可重复调用。
+ (void)startupCheck;

/// 手动激活（设置页输入卡密）。completion 主线程回调；ok=NO 时 message 为人话错误。
+ (void)activateCard:(NSString *)card
          completion:(void (^)(BOOL ok, NSString *message))completion;

// ── 网络请求参数（packs/download 调用方需要） ──

/// 当前 token（无则 nil）
+ (nullable NSString *)currentToken;

/// 设备 ID（IDFV；异常时用 Keychain 持久 UUID 兜底）
+ (NSString *)deviceID;

/// 设备尾号（展示用，deviceID 后 4 位）
+ (NSString *)deviceTail;

@end
