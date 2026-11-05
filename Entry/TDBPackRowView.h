//
//  TDBPackRowView.h
//  BubbleDeck
//
//  主题页气泡包行：圆角裁剪容器 + 卡片内容 + 左滑删除区。
//
//  红色永不渗出的三条不变量（改这里前先读懂）：
//    1. 全行只有容器一处圆角（cornerRadius 15 continuous + clipsToBounds），
//       卡片与删除区都是直角矩形，由容器裁出圆角；
//    2. 卡片与删除区始终相邻、永不重叠（同一 transform 同步平移）；
//    3. 容器底色 = 卡片底色，边缘即便有半像素也是白混白。
//

#import <UIKit/UIKit.h>

@interface TDBPackRowView : UIView

// 行宽 = 卡片宽（调用方负责 x/y）；pack = nil 表示「微信默认」卡（不可删）
- (instancetype)initWithWidth:(CGFloat)w
                         pack:(NSString *)pack
                        title:(NSString *)title
                     subtitle:(NSString *)subtitle
                        thumb:(UIImage *)thumb
                       active:(BOOL)active
                        badge:(NSString *)badge
                    deletable:(BOOL)deletable;

@property (nonatomic, copy, readonly) NSString *pack;
@property (nonatomic, readonly, getter=isOpen) BOOL open;

@property (nonatomic, copy) void (^onTap)(void);     // 点击卡片（收起态才触发）
@property (nonatomic, copy) void (^onOpen)(void);    // 滑开吸附完成
@property (nonatomic, copy) void (^onDelete)(void);

- (void)closeAnimated:(BOOL)animated;

@end
