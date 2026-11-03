//
//  TDLicense.m
//  BubbleDeck
//
//  Keychain 三项：token（7 天滚动）/ card（卡密，自动重激活用）/ lastVerify（兜底起点）。
//  状态机见头文件。所有网络在后台线程，内存状态写入后发通知，UI 收到重建。
//

#import "TDLicense.h"
#import "TDNet.h"
#import "TDLog.h"
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <objc/message.h>

NSNotificationName const TDLicenseStateChangedNotification = @"BubbleDeckLicenseStateChanged";

// ────── Keychain ──────

static NSString * const kKCService    = @"com.bubbledeck.auth";
static NSString * const kKCAccountToken      = @"token";
static NSString * const kKCAccountCard       = @"card";
static NSString * const kKCAccountLastVerify = @"lastVerify";
static NSString * const kKCAccountDevice     = @"device";

static NSDictionary *KCQuery(NSString *account) {
    return @{ (__bridge id)kSecClass       : (__bridge id)kSecClassGenericPassword,
              (__bridge id)kSecAttrService : kKCService,
              (__bridge id)kSecAttrAccount : account };
}

static NSString *KCGet(NSString *account);
static void KCDelete(NSString *account);

static NSString *KCGet(NSString *account) {
    NSMutableDictionary *q = [KCQuery(account) mutableCopy];
    q[(__bridge id)kSecReturnData]  = @YES;
    q[(__bridge id)kSecMatchLimit]  = (__bridge id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) != errSecSuccess) return nil;
    NSData *d = (__bridge_transfer NSData *)out;
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

static BOOL KCSet(NSString *account, NSString *value) {
    if (!value.length) { KCDelete(account); return YES; }
    NSDictionary *attrs = @{ (__bridge id)kSecValueData     : [value dataUsingEncoding:NSUTF8StringEncoding],
                             (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)KCQuery(account),
                                (__bridge CFDictionaryRef)attrs);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *add = [KCQuery(account) mutableCopy];
        [add addEntriesFromDictionary:attrs];
        st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    return st == errSecSuccess;
}

static void KCDelete(NSString *account) {
    SecItemDelete((__bridge CFDictionaryRef)KCQuery(account));
}

// ────── 内存状态 ──────
// s_active 是收费闸门的唯一判断源：Keychain 恢复 → verify/重激活结果 → 单向更新。

static TDLicenseState s_state = TDLicenseStateNotActivated;
static BOOL s_active = NO;
static BOOL s_restored = NO;

static void BDSetState(TDLicenseState st) {
    if (s_state == st && s_active == (st == TDLicenseStateActive)) return;
    s_state = st;
    s_active = (st == TDLicenseStateActive);
    TDLog(@"LIC", @"授权状态 → %ld", (long)st);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:TDLicenseStateChangedNotification
                                                            object:@(st)];
    });
}

// 上次报到距今 < 7 天 → 兜底期内仍算激活
static const NSTimeInterval kGraceSeconds = 7 * 86400;

static void BDRestoreFromKeychain(void) {
    if (s_restored) return;
    s_restored = YES;
    NSString *token = KCGet(kKCAccountToken);
    if (!token.length) {
        s_state = TDLicenseStateNotActivated;
        s_active = NO;
        return;
    }
    double last = [KCGet(kKCAccountLastVerify) doubleValue];
    BOOL withinGrace = (last > 0 && [[NSDate date] timeIntervalSince1970] - last < kGraceSeconds);
    s_state = withinGrace ? TDLicenseStateActive : TDLicenseStateGraceExpired;
    s_active = withinGrace;
    TDLog(@"LIC", @"启动恢复：token 存在，上次报到 %@（%@）",
          last > 0 ? [NSString stringWithFormat:@"%.0f 秒前", [[NSDate date] timeIntervalSince1970] - last] : @"无记录",
          withinGrace ? @"兜底期内" : @"兜底超期");
}

// ────── 设备信息 ──────

static NSString *BDModel(void) {
    struct utsname u;
    if (uname(&u) != 0) return @"unknown";
    return [NSString stringWithUTF8String:u.machine];
}

// wxid 仅作服务器记录展示，不作校验键——尽力抓，抓不到发空串
static NSString *BDWxid(void) {
    @try {
        id center = ((id (*)(id, SEL))objc_msgSend)(objc_getClass("MMServiceCenter"),
                                                    NSSelectorFromString(@"defaultCenter"));
        if (!center) return nil;
        // 候选：服务类名 + KVC 路径（微信版本差异，逐个试，全 @try 兜底）
        NSDictionary *cands = @{
            @"CContactMgr"             : @[@"selfContact.m_nsUsrName"],
            @"WCAccountServiceDataMgr" : @[@"accountInfo.m_nsUsrName", @"m_nsUsrName"],
        };
        for (NSString *svcName in cands) {
            Class cls = objc_getClass(svcName.UTF8String);
            if (!cls) continue;
            id svc = ((id (*)(id, SEL, Class))objc_msgSend)(center, NSSelectorFromString(@"getService:"), cls);
            if (!svc) continue;
            for (NSString *path in cands[svcName]) {
                id v = [svc valueForKeyPath:path];
                if ([v isKindOfClass:[NSString class]] && [v length]) return v;
            }
        }
    } @catch (NSException *e) {
        TDLogD(@"LIC", @"wxid 抓取失败（仅记录用，不影响激活）: %@", e.reason);
    }
    return nil;
}

// ────── 激活（同步，后台线程调用） ──────
// 成功：存 token/卡密/lastVerify，置 Active，返回 nil；失败返回人话错误。

static NSString *BDActivateSync(NSString *card) {
    NSDictionary *body = @{ @"license"   : card,
                            @"device_id" : [TDLicense deviceID],
                            @"wxid"      : (BDWxid() ?: @""),
                            @"sys"       : [NSString stringWithFormat:@"iOS %@",
                                            [UIDevice currentDevice].systemVersion],
                            @"model"     : BDModel() };
    NSDictionary *resp = [TDNet syncPostPath:@"activate" body:body];
    if (!resp) return [TDNet humanMessageForCode:-1 serverMsg:nil];
    NSInteger code = [resp[@"code"] integerValue];
    if (code != 0) {
        TDLog(@"LIC", @"activate 失败: %ld %@", (long)code, resp[@"msg"]);
        return [TDNet humanMessageForCode:code serverMsg:resp[@"msg"]];
    }
    NSString *token = resp[@"data"][@"token"];
    if (![token isKindOfClass:[NSString class]] || !token.length) return @"激活响应异常";
    KCSet(kKCAccountToken, token);
    KCSet(kKCAccountCard, card);
    KCSet(kKCAccountLastVerify,
          [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]]);
    BDSetState(TDLicenseStateActive);
    TDLog(@"LIC", @"激活成功，设备 %@", [TDLicense deviceID]);
    return nil;
}

// ────── 实现 ──────

@implementation TDLicense

+ (BOOL)isActiveNow {
    BDRestoreFromKeychain();
    return s_active;
}

+ (TDLicenseState)state {
    BDRestoreFromKeychain();
    return s_state;
}

+ (NSString *)currentToken { return KCGet(kKCAccountToken); }

+ (NSString *)deviceID {
    NSString *idfv = [UIDevice currentDevice].identifierForVendor.UUIDString;
    if (idfv.length) return idfv;
    NSString *d = KCGet(kKCAccountDevice);
    if (!d.length) {
        d = [NSUUID UUID].UUIDString;
        KCSet(kKCAccountDevice, d);
    }
    return d;
}

+ (NSString *)deviceTail {
    NSString *d = [self deviceID];
    return d.length >= 4 ? [d substringFromIndex:d.length - 4] : d;
}

+ (void)startupCheck {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BDRestoreFromKeychain();
        NSString *token = KCGet(kKCAccountToken);
        NSString *card  = KCGet(kKCAccountCard);

        if (!token.length && !card.length) {
            BDSetState(TDLicenseStateNotActivated);   // 无凭证：hook 全放行（首次调用不触发通知变更则无副作用）
            return;
        }

        if (token.length) {
            NSDictionary *resp = [TDNet syncPostPath:@"verify"
                                                body:@{ @"token"    : token,
                                                        @"device_id": [self deviceID] }];
            NSInteger code = resp ? [resp[@"code"] integerValue] : -1;
            if (code == 0) {
                KCSet(kKCAccountLastVerify,
                      [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]]);
                BDSetState(TDLicenseStateActive);
                return;
            }
            if (code == 2001) {
                // token 失效 → 用卡密自动重激活（无感续期）
                TDLog(@"LIC", @"token 失效，尝试卡密自动重激活");
                if (card.length) {
                    NSString *err = BDActivateSync(card);
                    if (!err) return;
                    TDLog(@"LIC", @"自动重激活失败: %@", err);
                    // 卡被停用(1002)/绑到别的设备(1003) → 清凭证回未激活；网络类错误 → 走兜底
                    if ([err containsString:@"停用"] || [err containsString:@"绑定"]) {
                        KCDelete(kKCAccountToken);
                        KCDelete(kKCAccountCard);
                        KCDelete(kKCAccountLastVerify);
                        BDSetState(TDLicenseStateNotActivated);
                        return;
                    }
                } else {
                    KCDelete(kKCAccountToken);
                    BDSetState(TDLicenseStateNotActivated);
                    return;
                }
            } else if (code != -1) {
                // 服务器明确拒绝（理论上 verify 只有 0/2001，防御性处理）
                TDLog(@"LIC", @"verify 异常响应: %ld", (long)code);
            }
            // 网络失败(-1) → 兜底判断（restore 已算好，若超期则维持）
            BDRestoreFromKeychain();
            BDSetState(s_state);
            return;
        }

        // 有卡密无 token（异常残留）→ 直接重激活
        NSString *err = BDActivateSync(card);
        if (err) TDLog(@"LIC", @"残留卡密重激活失败: %@", err);
    });
}

+ (void)activateCard:(NSString *)card
          completion:(void (^)(BOOL ok, NSString *message))completion {
    NSString *trimmed = [card stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *err = trimmed.length ? BDActivateSync(trimmed) : @"请输入卡密";
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(err == nil, err ?: @"激活成功");
        });
    });
}

@end
