//
//  TDBThemePageVC.m
//  BubbleDeck
//
//  主题页（逻辑自 v0.4.x TDBubbleEntry.m 平移，业务不变）：
//  只列已下载且授权有效的包（微信默认 + 本地包），点卡片启用。
//

#import "TDBPages.h"
#import "../TDBUI.h"
#import "../TDBPackRowView.h"
#import "../../Core/TDLog.h"
#import "../../Core/TDConfig.h"
#import "../../Core/TDLicense.h"
#import "../../Engine/TDPackLoader.h"
#import "../../Engine/TDContainer.h"

@interface TDBThemePageVC () <UIScrollViewDelegate>
@property (nonatomic, strong) NSMutableArray<TDBPackRowView *> *rows;
@end

@implementation TDBThemePageVC

- (void)viewDidLoad {
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL))method_getImplementation(m))(self, _cmd);
    self.title = @"更换气泡";
}

- (void)viewWillAppear:(BOOL)animated {
    Method m = class_getInstanceMethod([UIViewController class], _cmd);
    if (m) ((void (*)(id, SEL, BOOL))method_getImplementation(m))(self, _cmd, animated);

    self.view.backgroundColor = BDPageBg();
    if (self.view.bounds.size.width < 1) return;
    [self buildPage];
}

// ────── 页面构建 ──────

- (void)buildPage {
    for (UIView *sub in self.view.subviews) [sub removeFromSuperview];

    CGFloat w = self.view.bounds.size.width;
    UIScrollView *scroll = BDNewScroll(self);
    scroll.delegate = self;
    _rows = [NSMutableArray array];

    CGFloat y = 16;

    NSString *active = [TDConfig activePack];
    NSArray<NSString *> *packs = [TDConfig availablePacks];
    // 激活名在包列表里不存在 = 配置残留，按未激活处理并清理
    if (active && ![packs containsObject:active]) {
        TDLog(@"DEV", @"[activePack] 指向不存在的包 %@，清理", active);
        [TDConfig setActivePack:nil];
        active = nil;
    }

    __weak typeof(self) ws = self;

    // 微信默认卡
    TDBPackRowView *defRow = [[TDBPackRowView alloc]
        initWithWidth:w - 30 pack:nil title:@"微信默认"
              subtitle:@"不使用任何气泡包，恢复微信原生气泡"
                 thumb:nil active:(active == nil) badge:nil deletable:NO];
    defRow.frame = CGRectMake(15, y, w - 30, 76);
    defRow.onTap = ^{ [ws bdTapPack:nil]; };
    [scroll addSubview:defRow];
    [_rows addObject:defRow];
    y += 76 + 12;

    // 本地已装的在线包全部显示，按授权状态标灰（封禁/未授权/待验证），点击时拦截
    BOOL anyShown = NO;
    for (NSString *name in packs) {
        NSString *badge = nil;
        if ([[TDConfig sourceForPack:name] isEqualToString:@"online"]) {
            if ([TDLicense entitlementsExpired])      badge = @"待验证";
            else if ([TDLicense isRevokedPack:name])  badge = @"已封禁";
            else if (![TDLicense isOwnedPack:name])   badge = @"未授权";
        }

        NSString *dir = [TDPackLoader packDirForName:name];
        UIImage *thumb = nil;
        // 分流：盘上常密包（V3）icon 走容器索引；明文目录包走原逻辑
        if (dir && [[NSFileManager defaultManager]
                    fileExistsAtPath:[dir stringByAppendingPathComponent:@"pack.bdpack"]]) {
            NSError *err = nil;
            TDContainer *c = [TDContainer cachedContainerForPack:name error:&err];
            if (c) {
                thumb = [UIImage imageWithData:[c dataForEntry:@"icon.png"]];
            } else {
                TDLog(@"DEV", @"[主题页] 容器打开失败: %@ - %@", name, err.localizedDescription);
            }
        } else {
            thumb = dir
                ? [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:@"icon.png"]]
                : nil;
        }
        // 副标题 = 作者名（info.json 安装时明文落盘，无需 key/容器/网络；
        // 封禁、待验证、未授权卡均正常显示）。无 author 兜底「未知作者」。
        NSString *author = nil;
        if (dir) {
            NSData *infoData = [NSData dataWithContentsOfFile:
                                [dir stringByAppendingPathComponent:@"info.json"]];
            id obj = infoData ? [NSJSONSerialization JSONObjectWithData:infoData options:0 error:nil] : nil;
            id a = [obj isKindOfClass:[NSDictionary class]] ? obj[@"author"] : nil;
            if ([a isKindOfClass:[NSString class]] && [(NSString *)a length]) author = a;
        }
        NSString *subtitle = author ?: @"未知作者";

        // 行 = 圆角裁剪容器 + 卡片内容 + 删除区（微信默认卡不可删）
        TDBPackRowView *row = [[TDBPackRowView alloc]
            initWithWidth:w - 30 pack:name title:name subtitle:subtitle
                    thumb:thumb active:[active isEqualToString:name] badge:badge
                deletable:YES];
        row.frame = CGRectMake(15, y, w - 30, 76);
        __weak TDBPackRowView *weakRow = row;
        row.onTap = ^{ [ws bdTapPack:name]; };
        row.onOpen = ^{ [ws bdCloseRowsExcept:weakRow]; };
        row.onDelete = ^{ [ws bdDeletePack:name]; };
        [scroll addSubview:row];
        [_rows addObject:row];
        y += 76 + 12;
        anyShown = YES;
    }

    if (!anyShown) {
        y = BDEmptyHint(self, scroll, y,
                        @"还没有已下载的气泡包\n先回主页「下载气泡」获取");
    }

    y = BDFooter(self, scroll, y);
    scroll.contentSize = CGSizeMake(w, y);
}

// ────── 交互 ──────

// 关闭除 keep 以外的所有行（同屏只允许一行展开）
- (void)bdCloseRowsExcept:(TDBPackRowView *)keep {
    for (TDBPackRowView *row in _rows) {
        if (row != keep) [row closeAnimated:YES];
    }
}

// 滚动开始：收起所有已展开的行
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    [self bdCloseRowsExcept:nil];
}

// 卡片：启用 / 恢复默认
- (void)bdTapPack:(NSString *)pack {
    [self bdCloseRowsExcept:nil];
    NSString *active = [TDConfig activePack];

    if (pack == nil) {
        // 微信默认卡：仅在当前有激活气泡包时提供恢复
        if (!active) return;
        BDShowConfirm(self, @"恢复微信默认",
                      [NSString stringWithFormat:@"将停用「%@」，恢复微信原生气泡。", active],
                      @"恢复默认", YES, ^{
            [TDConfig setActivePack:nil];
            TDLog(@"DEV", @"[Pack] 恢复微信默认（原 %@）", active);
            [self buildPage];
        });
        return;
    }

    if ([pack isEqualToString:active]) return; // 已在使用，无操作

    // 安全网：主题页会显示标灰的不可用包，这里按状态拦截（授权可能在页面停留期间变化）
    if ([[TDConfig sourceForPack:pack] isEqualToString:@"online"]
        && ![TDLicense gateOpenForPack:pack]) {
        if ([TDLicense entitlementsExpired]) {
            BDShowAlert(self, @"暂时无法验证",
                        [NSString stringWithFormat:@"「%@」需要联网验证授权后才能使用，请检查网络后重进本页。", pack],
                        @"好");
        } else if ([TDLicense isRevokedPack:pack]) {
            BDShowAlert(self, @"已被封禁",
                        [NSString stringWithFormat:@"「%@」的激活码已被封禁，如有疑问请联系卖家。", pack],
                        @"好");
        } else {
            BDShowAlert(self, @"未授权",
                        [NSString stringWithFormat:@"当前微信号没有「%@」的授权，请激活对应激活码后使用。", pack],
                        @"好");
        }
        return;
    }

    BDShowConfirm(self, @"启用气泡包",
                  [NSString stringWithFormat:@"启用「%@」？\n新打开的聊天页生效。", pack],
                  @"启用", NO, ^{
        [TDConfig setActivePack:pack];
        TDLog(@"DEV", @"[Pack] 激活气泡包: %@", pack);
        [self buildPage];
    });
}

// 删除气泡包
- (void)bdDeletePack:(NSString *)pack {
    if (!pack.length) return;
    BOOL isActive = [[TDConfig activePack] isEqualToString:pack];

    NSString *msg = isActive
        ? [NSString stringWithFormat:@"「%@」正在使用中，删除后将恢复微信默认气泡。", pack]
        : [NSString stringWithFormat:@"「%@」将从本机删除。\n服务器授权保留，以后可重新下载。", pack];
    BDShowConfirm(self, @"删除气泡包", msg, @"删除", YES, ^{
        NSString *dir = [TDPackLoader packDirForName:pack];
        if (dir) [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
        [TDContainer purgeContainerForPack:pack];
        if (isActive) {
            [TDConfig setActivePack:nil];
            TDLog(@"DEV", @"[Pack] 删除正在使用的包，恢复微信默认: %@", pack);
        }
        TDLog(@"DEV", @"[Pack] 已删除气泡包: %@", pack);
        [self buildPage];
    });
}

@end
