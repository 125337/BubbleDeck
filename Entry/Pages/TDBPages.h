//
//  TDBPages.h
//  BubbleDeck
//
//  插件页四个页面 VC 的编译期声明（Mio SettingCategoryController 同位）：
//  每页 = 真实 ObjC 类（不继承微信类），push 到微信导航栈，
//  原生导航栏的标题/返回键随 push/pop 自动工作。
//

#import <UIKit/UIKit.h>

@interface TDBMainPageVC : UIViewController
@end

@interface TDBStorePageVC : UIViewController
/// 清「本次会话已尝试拉清单」标记（设置页「重新加载」后允许商店页重试报到）
+ (void)resetFetchState;
@end

@interface TDBThemePageVC : UIViewController
@end

@interface TDBSettingsPageVC : UIViewController
@end
