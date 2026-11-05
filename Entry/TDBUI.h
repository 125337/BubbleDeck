//
//  TDBUI.h
//  BubbleDeck
//
//  插件页共享自绘组件库（Mio Settings/Common 同位）：
//  灰底白卡分组风格（iOS 分组列表配色），全部 frame 布局（禁 Auto Layout，
//  v0.4.0 曾因 safeArea 约束崩溃）。四个页面 VC 共用本库，导航栏交给微信原生。
//

#import <UIKit/UIKit.h>

// ── 配色 ──
UIColor *BDPageBg(void);        // 页面底：分组列表浅灰
UIColor *BDCardBg(void);        // 卡片底：白
UIColor *BDChipBg(void);        // 卡片内次级按钮/胶囊底
UIColor *BDSecondaryText(void); // 次级文字
UIColor *BDTint(void);          // 主色（蓝）

// ── 布局 ──
// 导航栏底边 y = navigationBar.frame 实测（Mio wpLayoutInContainer 同款）；
// view 未挂 window 时兜底 64。所有页面内容从该值起算。
CGFloat BDNavBarHeight(UIViewController *vc);

// 创建页面主滚动容器（挂在 vc.view 上，frame 从导航栏下方起算）
UIScrollView *BDNewScroll(UIViewController *vc);

// 空状态提示卡；返回新的 y
CGFloat BDEmptyHint(UIViewController *vc, UIScrollView *scroll, CGFloat y, NSString *text);

// 页脚；返回新的 y
CGFloat BDFooter(UIViewController *vc, UIScrollView *scroll, CGFloat y);

// 通用行卡（左标题 + 右箭头；高度 46；tapSel 挂在 vc 上）
UIView *BDRowCard(UIViewController *vc, UIScrollView *scroll, CGFloat y,
                  NSString *title, SEL tapSel);

// 气泡包卡片（packName = nil 表示「微信默认」卡；isActive 决定右侧徽章样式）。
// badgeText 非空 → 卡片灰显并显示该角标（如「已封禁」），替代箭头/使用中徽章。
// 点按手势由调用方挂；packName 挂在卡片 associated object "pack" 上。
UIView *BDMakeCard(CGFloat y, CGFloat w, NSString *packName, NSString *title,
                   NSString *subtitle, UIImage *thumb, BOOL isActive, NSString *badgeText);

// ── 工具 ──
NSInteger BDPackImageCount(NSString *dir);   // 解包目录位图文件数
NSString *BDFileSize(long long bytes);

// ── 弹窗 ──
// 单按钮提示
void BDShowAlert(UIViewController *vc, NSString *title, NSString *message, NSString *okTitle);
// 双按钮确认（onConfirm 主按钮回调）
void BDShowConfirm(UIViewController *vc, NSString *title, NSString *message,
                   NSString *okTitle, BOOL destructive, void (^onConfirm)(void));
