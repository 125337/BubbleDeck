//
//  TDBPackRowView.m
//  BubbleDeck
//
//  行结构：容器（唯一圆角） │ 卡片内容（直角） │ 删除区（直角，初始在容器裁剪区外）
//  拖动时两者用同一 transform 平移，所以永远相邻不重叠。
//

#import "TDBPackRowView.h"
#import "TDBUI.h"

static const CGFloat kBDCorner      = 15.0;
static const CGFloat kBDDeleteWidth = 84.0;

// 删除区红：浅色 #FF3B30 / 深色 #FF453A（系统红），按压加深一档
static UIColor *BDDeleteRed(void) {
    if (@available(iOS 13.0, *)) return [UIColor systemRedColor];
    return [UIColor colorWithRed:1.0 green:0.23 blue:0.19 alpha:1.0];
}

static UIColor *BDDeleteRedPressed(void) {
    return [UIColor colorWithRed:0.84 green:0.13 blue:0.10 alpha:1.0];
}

// 卡片按压态：透明黑 4% overlay（玻璃卡不改背景色）

@interface TDBPackRowView () <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIView *pressOverlay;  // 按压反馈：透明黑 4% overlay
@property (nonatomic, strong) UIControl *deleteView;
@property (nonatomic, assign) CGFloat offset;      // 当前平移量（负数 = 左滑）
@property (nonatomic, assign) CGFloat panStart;
@end

@implementation TDBPackRowView

- (instancetype)initWithWidth:(CGFloat)w
                         pack:(NSString *)pack
                        title:(NSString *)title
                     subtitle:(NSString *)subtitle
                        thumb:(UIImage *)thumb
                       active:(BOOL)active
                        badge:(NSString *)badge
                    deletable:(BOOL)deletable {
    self = [super initWithFrame:CGRectMake(0, 0, w, 76)];
    if (!self) return nil;

    _pack = [pack copy];

    // 不变量 1：全行唯一的圆角来源
    self.backgroundColor = [UIColor clearColor]; // 不变量 3：玻璃磨砂在卡片内，容器保持透明
    self.layer.cornerRadius = kBDCorner;
    if (@available(iOS 13.0, *)) self.layer.cornerCurve = kCACornerCurveContinuous;
    self.clipsToBounds = YES;
    if (active && !badge.length) {
        self.layer.borderWidth = 1.5;
        self.layer.borderColor = BDTint().CGColor;
    }

    _contentView = BDCardContentView(w, title, subtitle, thumb, active, badge);
    // 卡片底 → 分层玻璃材质（失败兜底回填不透明白卡，绝不 crash；删除区红为实色不受影响）
    if (!BDInstallGlassMaterial(_contentView)) _contentView.backgroundColor = BDCardBg();
    [self addSubview:_contentView];

    // 按压反馈 overlay：盖在卡片内容之上（透明黑 4%，不改背景色）
    _pressOverlay = [[UIView alloc] initWithFrame:_contentView.bounds];
    _pressOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _pressOverlay.userInteractionEnabled = NO;
    _pressOverlay.backgroundColor = [UIColor blackColor];
    _pressOverlay.alpha = 0;
    [_contentView addSubview:_pressOverlay];

    if (deletable) {
        // 不变量 2：删除区初始整体位于容器裁剪区之外（x = w 起），静止时不可见
        _deleteView = [[UIControl alloc] initWithFrame:CGRectMake(w, 0, kBDDeleteWidth, self.bounds.size.height)];
        _deleteView.backgroundColor = BDDeleteRed();
        UILabel *lb = [[UILabel alloc] initWithFrame:_deleteView.bounds];
        lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.text = @"删除";
        lb.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        lb.textColor = [UIColor whiteColor];
        lb.textAlignment = NSTextAlignmentCenter;
        [_deleteView addSubview:lb];
        [_deleteView addTarget:self action:@selector(bdDeleteDown)
               forControlEvents:UIControlEventTouchDown];
        [_deleteView addTarget:self action:@selector(bdDeleteRestore)
               forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside |
                                UIControlEventTouchCancel];
        [_deleteView addTarget:self action:@selector(bdDeleteTriggered)
               forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_deleteView];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(bdPan:)];
        pan.delegate = self;
        [self addGestureRecognizer:pan];
    }

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(bdTap:)];
    [_contentView addGestureRecognizer:tap];

    return self;
}

// 只让横向意图的拖动接管（竖直方向放行给父滚动视图）
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gr {
    if ([gr isKindOfClass:[UIPanGestureRecognizer class]]) {
        CGPoint v = [(UIPanGestureRecognizer *)gr velocityInView:self];
        return fabs(v.x) > fabs(v.y);
    }
    return YES;
}

// ────── 平移 ──────

- (void)bdApplyOffset:(CGFloat)t {
    _offset = t;
    CGAffineTransform tr = CGAffineTransformMakeTranslation(t, 0);
    _contentView.transform = tr;
    _deleteView.transform = tr;        // 同一 transform：两者永远相邻、不重叠
}

- (UIScrollView *)bdEnclosingScroll {
    UIView *v = self.superview;
    while (v && ![v isKindOfClass:[UIScrollView class]]) v = v.superview;
    return (UIScrollView *)v;
}

- (void)bdPan:(UIPanGestureRecognizer *)gr {
    UIScrollView *scroll = [self bdEnclosingScroll];

    if (gr.state == UIGestureRecognizerStateBegan) {
        _panStart = _offset;
        scroll.panGestureRecognizer.enabled = NO;   // 横向拖动期间锁滚动，结束恢复
        [self bdSetPressed:NO];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGFloat t = _panStart + [gr translationInView:self].x;
        if (t > 0) t /= 3;                                                  // 右滑橡皮筋
        else if (t < -kBDDeleteWidth) t = -kBDDeleteWidth + (t + kBDDeleteWidth) / 3; // 露头橡皮筋
        [self bdApplyOffset:t];
    } else {
        scroll.panGestureRecognizer.enabled = YES;
        CGFloat vx = [gr velocityInView:self].x;
        BOOL open = (vx < -20) ? YES : ((vx > 20) ? NO : (_offset < -kBDDeleteWidth / 2));
        [self bdSnapTo:open velocity:vx];
    }
}

- (void)bdSnapTo:(BOOL)open velocity:(CGFloat)vx {
    if (open && !_deleteView) open = NO;
    BOOL wasOpen = _open;
    _open = open;
    _offset = open ? -kBDDeleteWidth : 0;

    // 弹簧初速度：每秒位移占满行程的比例
    CGFloat v = vx / kBDDeleteWidth;
    if (v > 3.0) v = 3.0;
    if (v < -3.0) v = -3.0;

    [UIView animateWithDuration:0.34 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:v
                        options:UIViewAnimationOptionBeginFromCurrentState |
                                UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        [self bdApplyOffset:open ? -kBDDeleteWidth : 0];
    } completion:nil];

    if (open && !wasOpen) {
        UIImpactFeedbackGenerator *h = [[UIImpactFeedbackGenerator alloc]
            initWithStyle:UIImpactFeedbackStyleLight];
        [h impactOccurred];
        void (^cb)(void) = self.onOpen;
        if (cb) cb();
    }
}

- (void)closeAnimated:(BOOL)animated {
    if (!_open && _offset == 0) return;
    _open = NO;
    _offset = 0;
    if (animated) {
        [UIView animateWithDuration:0.28 delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ [self bdApplyOffset:0]; } completion:nil];
    } else {
        [self bdApplyOffset:0];
    }
}

// ────── 交互 ──────

- (void)bdTap:(UITapGestureRecognizer *)gr {
    if (_open) { [self bdSnapTo:NO velocity:0]; return; }   // 打开态点卡片 = 收起
    void (^tap)(void) = self.onTap;                         // 局部持有：回调里可能重建页面释放本行
    if (tap) tap();
}

- (void)bdDeleteDown { _deleteView.backgroundColor = BDDeleteRedPressed(); }
- (void)bdDeleteRestore { _deleteView.backgroundColor = BDDeleteRed(); }

- (void)bdDeleteTriggered {
    [self bdDeleteRestore];
    void (^del)(void) = self.onDelete;
    if (del) del();
}

// ────── 卡片按压态 ──────

- (void)bdSetPressed:(BOOL)pressed {
    if (pressed && _deleteView && _offset != 0) return;   // 滑开态不做按压反馈
    _pressOverlay.alpha = pressed ? 0.04 : 0;             // 透明黑 4% overlay，不改背景色
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    [self bdSetPressed:YES];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    [self bdSetPressed:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    [self bdSetPressed:NO];
}

@end
