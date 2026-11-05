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

// 气泡包卡片「内容」（0 原点、直角、透明底）：缩略图 + 标题 + 副标题 + 右侧徽章/箭头。
// 注意：这里不画圆角——圆角统一由外层裁剪容器提供（TDBPackRowView），
// 保证一行里只有一处圆角光栅化。badgeText 非空 → 显示该角标并替代箭头/使用中徽章。
// 卡片底色（玻璃/兜底白）由外层安装，这里只做内容与布局。
UIView *BDCardContentView(CGFloat w, NSString *title, NSString *subtitle,
                          UIImage *thumb, BOOL isActive, NSString *badgeText);

// ── 分层液态玻璃（三级降级：iOS 26 原生 UIGlassEffect → 13–25 磨砂+描边 → 白卡兜底）──
// 在 host（须已设圆角 + clipsToBounds）底部安装玻璃材质层。
// 返回 YES = 材质可用（host 背景保持透明）；NO = 失败（调用方回填不透明白卡底色）。
// iOS 26 走运行时探测的 UIGlassEffect（不编译期引用，SDK 版本不确定），全程 @try 守卫。
BOOL BDInstallGlassMaterial(UIView *host);

// 玻璃卡片壳：外投影 + 圆角裁剪玻璃容器（corner = 圆角半径，内容 addSubview 到返回视图）
UIView *BDGlassCard(CGRect frame, CGFloat corner);

// 下载按钮 tinted glass 底：磨砂 + 琥珀 #E8A33D overlay(α0.85) + 白描边，文字保持白色
void BDStyleAmberGlassButton(UIButton *btn);

// 页面底层中性纹理装饰层：白/黑径向 blob + 超大低透明度水印（纯明度无色相）。
// 插在 host 最底层（页面背景之上、scroll 之下），不随列表滚动，给玻璃提供「可磨」的背景。
void BDInstallGlassBackdrop(UIView *host);

// ── 工具 ──
NSString *BDFileSize(long long bytes);

// ── 弹窗 ──
// 单按钮提示
void BDShowAlert(UIViewController *vc, NSString *title, NSString *message, NSString *okTitle);
// 双按钮确认（onConfirm 主按钮回调）
void BDShowConfirm(UIViewController *vc, NSString *title, NSString *message,
                   NSString *okTitle, BOOL destructive, void (^onConfirm)(void));
