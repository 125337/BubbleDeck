//
//  TDLicense.m
//  BubbleDeck
//
//  V2 授权模型（相比 V1 净减 ~100 行：无 token 状态机/自愈/兜底计时）。
//  Keychain 四项：cachedWxid / entitlements（清单 JSON）/ lastSync（报到时间戳）/
//  device（IDFV 异常兜底 UUID）。V1 遗留字段（token/card/lastVerify）启动清理一次。
//  清单读取全部走内存缓存——闸门在微信取图热路径上，禁止每次 Keychain IO。
//

#import "TDLicense.h"
#import "TDNet.h"
#import "TDLog.h"
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <objc/message.h>

NSNotificationName const TDLicenseStateChangedNotification = @"BubbleDeckLicenseStateChanged";

// ────── Keychain ──────

static NSString * const kKCService = @"com.bubbledeck.auth";
static NSString * const kKCAccountWxid   = @"cachedWxid";
static NSString * const kKCAccountEnts   = @"entitlements";
static NSString * const kKCAccountSync   = @"lastSync";
static NSString * const kKCAccountDevice = @"device";
// V1 遗留字段（启动清理一次）
static NSArray<NSString *> *kKCLegacyAccounts(void) {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = @[@"token", @"card", @"lastVerify"]; });
    return a;
}

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

static BOOL s_legacyCleaned = NO;
static void BDCleanLegacy(void) {
    if (s_legacyCleaned) return;
    s_legacyCleaned = YES;
    for (NSString *a in kKCLegacyAccounts()) KCDelete(a);
}

// ────── 内存缓存（热路径安全） ──────

static NSArray<NSDictionary *> *s_ents = nil;   // 解析后的 packs 清单
static BOOL s_entsLoaded = NO;
static double s_lastSync = -1;                  // -1 = 未从 Keychain 加载
static BOOL s_syncing = NO;

static double BDLastSync(void) {
    if (s_lastSync < 0) s_lastSync = [KCGet(kKCAccountSync) doubleValue];
    return s_lastSync;
}

static void BDLoadEnts(void) {
    if (s_entsLoaded) return;
    s_entsLoaded = YES;
    BDCleanLegacy();
    NSString *json = KCGet(kKCAccountEnts);
    if (!json.length) return;
    NSData *d = [json dataUsingEncoding:NSUTF8StringEncoding];
    id obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if ([obj isKindOfClass:[NSArray class]]) s_ents = obj;
}

static void BDSaveEnts(NSArray *packs) {
    s_ents = packs;
    s_entsLoaded = YES;
    NSData *d = [NSJSONSerialization dataWithJSONObject:packs options:0 error:nil];
    KCSet(kKCAccountEnts,
          d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil);
    s_lastSync = [[NSDate date] timeIntervalSince1970];
    KCSet(kKCAccountSync, [NSString stringWithFormat:@"%.0f", s_lastSync]);
}

// 离线兜底：上次报到距今 7 天内有效
static const NSTimeInterval kCacheSeconds = 7 * 86400;

// ────── 设备信息 ──────

static NSString *BDModel(void) {
    struct utsname u;
    if (uname(&u) != 0) return @"unknown";
    return [NSString stringWithUTF8String:u.machine];
}

// Mio 实证同款（8.0.60）：MMContext currentContext getService: 优先，
// MMServiceCenter defaultCenter 兜底但必须带 respondsToSelector 守卫
//（8.0.60 原生可能没有 defaultCenter 类方法，无守卫直调抛异常）。
static id BDGetService(Class serviceClass) {
    if (!serviceClass) return nil;
    Class mmctx = objc_getClass("MMContext");
    if (mmctx && [mmctx respondsToSelector:@selector(currentContext)]) {
        id ctx = ((id (*)(id, SEL))objc_msgSend)(mmctx, @selector(currentContext));
        if (ctx && [ctx respondsToSelector:@selector(getService:)]) {
            id svc = ((id (*)(id, SEL, Class))objc_msgSend)(ctx, @selector(getService:), serviceClass);
            if (svc) return svc;
        }
    }
    Class mmCenter = objc_getClass("MMServiceCenter");
    if (mmCenter && [mmCenter respondsToSelector:NSSelectorFromString(@"defaultCenter")]) {
        id center = ((id (*)(id, SEL))objc_msgSend)(mmCenter, NSSelectorFromString(@"defaultCenter"));
        if (center && [center respondsToSelector:@selector(getService:)]) {
            return ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), serviceClass);
        }
    }
    return nil;
}

// wxid：CContactMgr getSelfContact → m_nsUsrName（Mio ServiceHelper 同款，selector 直调非 KVC）。
// 绑定主键就是 wxid，抓不到时激活本地拦截；报到时用上次缓存兜底。
static NSString *BDWxid(void) {
    @try {
        id contactMgr = BDGetService(objc_getClass("CContactMgr"));
        if (contactMgr && [contactMgr respondsToSelector:@selector(getSelfContact)]) {
            id selfContact = ((id (*)(id, SEL))objc_msgSend)(contactMgr, @selector(getSelfContact));
            SEL usrSel = NSSelectorFromString(@"m_nsUsrName");
            if (selfContact && [selfContact respondsToSelector:usrSel]) {
                id v = ((id (*)(id, SEL))objc_msgSend)(selfContact, usrSel);
                if ([v isKindOfClass:[NSString class]] && [v length]) return v;
            }
        }
    } @catch (NSException *e) {
        TDLogD(@"LIC", @"wxid 抓取失败: %@", e.reason);
    }
    return nil;
}

// ────── 同步报到（后台线程调用） ──────

static BOOL BDSyncNow(void) {
    NSString *wxid = BDWxid() ?: KCGet(kKCAccountWxid) ?: @"";
    NSDictionary *resp = [TDNet syncPostPath:@"packs"
                                        body:@{ @"device_id": [TDLicense deviceID],
                                                @"wxid"      : wxid }];
    NSInteger code = resp ? [resp[@"code"] integerValue] : -1;
    id arr = resp[@"data"][@"packs"];
    if (code != 0 || ![arr isKindOfClass:[NSArray class]]) {
        TDLog(@"LIC", @"报到失败: %ld（沿用缓存清单）", (long)code);
        return NO;
    }
    BDSaveEnts(arr);
    if (wxid.length) KCSet(kKCAccountWxid, wxid);
    NSUInteger owned = 0;
    for (NSDictionary *p in arr) {
        if ([p isKindOfClass:[NSDictionary class]] && [p[@"owned"] boolValue]) owned++;
    }
    TDLog(@"LIC", @"报到成功：%lu 个包（owned %lu）",
          (unsigned long)[arr count], (unsigned long)owned);
    return YES;
}

// ────── 实现 ──────

@implementation TDLicense

+ (void)refreshEntitlementsWithCompletion:(void (^)(BOOL))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = BDSyncNow();
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:TDLicenseStateChangedNotification object:nil];
            if (completion) completion(ok);
        });
    });
}

+ (void)refreshEntitlements {
    [self refreshEntitlementsWithCompletion:nil];
}

+ (void)activateLicense:(NSString *)license
             completion:(void (^)(BOOL ok, NSString *message))completion {
    NSString *trimmed = [license stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        void (^done)(BOOL, NSString *) = ^(BOOL ok, NSString *msg) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(ok, msg);
            });
        };

        if (!trimmed.length) { done(NO, @"请输入激活码"); return; }

        // 绑定主键就是 wxid，抓不到不发请求
        NSString *wxid = BDWxid();
        if (!wxid.length) { done(NO, @"请先登录微信后再激活"); return; }

        NSDictionary *body = @{ @"license"   : trimmed,
                                @"device_id" : [TDLicense deviceID],
                                @"wxid"      : wxid,
                                @"sys"       : [NSString stringWithFormat:@"iOS %@",
                                                [UIDevice currentDevice].systemVersion],
                                @"model"     : BDModel() };
        NSDictionary *resp = [TDNet syncPostPath:@"activate" body:body];
        NSInteger code = resp ? [resp[@"code"] integerValue] : -1;
        if (code != 0) {
            TDLog(@"LIC", @"activate 失败: %ld %@", (long)code, resp[@"msg"] ?: @"网络失败");
            done(NO, [TDNet humanMessageForCode:code serverMsg:resp[@"msg"]]);
            return;
        }

        // 入账成功：码即忘，缓存 wxid，立刻同步报到把新授权拉回来（UI 重建即见[下载]）
        KCSet(kKCAccountWxid, wxid);
        BDSyncNow();
        NSString *packName = resp[@"data"][@"pack_name"];
        TDLog(@"LIC", @"激活成功: %@", packName);
        done(YES, [NSString stringWithFormat:@"已激活 · %@",
                   [packName isKindOfClass:[NSString class]] && packName.length ? packName : @"气泡包"]);
    });
}

+ (NSArray<NSDictionary *> *)entitlements {
    BDLoadEnts();
    return s_ents;
}

+ (BOOL)entitlementsExpired {
    double last = BDLastSync();
    return !(last > 0 && [[NSDate date] timeIntervalSince1970] - last < kCacheSeconds);
}

+ (BOOL)isOwnedPack:(NSString *)name {
    if (!name.length) return NO;
    BDLoadEnts();
    for (NSDictionary *p in s_ents) {
        if ([p isKindOfClass:[NSDictionary class]] && [p[@"owned"] boolValue]
            && [name isEqualToString:p[@"name"]]) return YES;
    }
    return NO;
}

+ (BOOL)gateOpenForPack:(NSString *)name {
    if ([self entitlementsExpired]) return NO;
    return [self isOwnedPack:name];
}

+ (NSString *)keyForPack:(NSString *)name {
    if (!name.length) return nil;
    BDLoadEnts();
    for (NSDictionary *p in s_ents) {
        if ([p isKindOfClass:[NSDictionary class]] && [p[@"owned"] boolValue]
            && [name isEqualToString:p[@"name"]]) {
            return [p[@"key"] isKindOfClass:[NSString class]] ? p[@"key"] : nil;
        }
    }
    return nil;
}

+ (NSString *)currentWxid {
    NSString *w = BDWxid();
    if (w.length) return w;
    return KCGet(kKCAccountWxid);
}

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

@end
