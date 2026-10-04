// QEOverlay.m
// ---------------------------------------------------------------------------
// 精简悬浮窗实现。设计要点:
//   1. 绝不 hook 任何系统方法, 只用公开 API (addSubview 到宿主 window)
//   2. 所有 UI 操作强制在主线程, 且用 dispatch_async 避免在系统路径里同步阻塞
//   3. 文本只追加到 UITextView, 不调用任何可能重入 format hook 的路径
//   4. 面板可拖动, 有清空/复制按钮
//   5. 面板尺寸**不依赖挂载时的 host.bounds** (早期可能为 0),
//      改为在 layoutSubviews 里按当前 bounds 重新计算, 避免出现极窄/零高度
// ---------------------------------------------------------------------------

#import "QEOverlay.h"

@interface QEOverlayPanel : UIView
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *panelBox;
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGPoint panelOrigin;
@property (nonatomic, assign) BOOL boxPositioned;
- (void)renderText;   // 供 QEOverlayAppend 调用
@end

static QEOverlayPanel *gPanel = nil;
static NSMutableString *gText = nil;   // 单一数据源, 避免反复读 tv.text
static dispatch_once_t gTextOnce;

#pragma mark - 宿主 window

static UIWindow *QEHostWindow(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) return nil;

    UIWindow *fallback = app.delegate.window;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) continue;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow && w.windowLevel == UIWindowLevelNormal) return w;
            }
            for (UIWindow *w in ws.windows) {
                if (w.windowLevel == UIWindowLevelNormal) return w;
            }
        }
    }
    if (fallback && fallback.windowLevel == UIWindowLevelNormal) return fallback;
    return nil;
}

#pragma mark - 面板

@implementation QEOverlayPanel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self buildSubviews];
    }
    return self;
}

- (void)buildSubviews {
    UIColor *green = [UIColor systemGreenColor];

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(10, 80, 340, 300)];
    box.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
    box.layer.cornerRadius = 12.0;
    box.layer.borderWidth = 1.0;
    box.layer.borderColor = [green colorWithAlphaComponent:0.5].CGColor;
    box.clipsToBounds = YES;
    box.autoresizingMask = UIViewAutoresizingNone;
    [self addSubview:box];
    self.panelBox = box;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, box.bounds.size.width, 30)];
    bar.backgroundColor = [green colorWithAlphaComponent:0.25];
    bar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [box addSubview:bar];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, box.bounds.size.width - 130, 30)];
    lbl.text = @"QE_SIGN_HOOK";
    lbl.font = [UIFont boldSystemFontOfSize:13];
    lbl.textColor = green;
    lbl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [bar addSubview:lbl];
    self.titleLabel = lbl;

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(box.bounds.size.width - 104, 3, 46, 24);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:13];
    clear.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [clear addTarget:self action:@selector(onClear) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:clear];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(box.bounds.size.width - 54, 3, 46, 24);
    [copy setTitle:@"复制" forState:UIControlStateNormal];
    copy.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    copy.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [copy addTarget:self action:@selector(onCopy) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:copy];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [bar addGestureRecognizer:pan];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(6, 34, box.bounds.size.width - 12, box.bounds.size.height - 40)];
    tv.backgroundColor = [UIColor clearColor];
    tv.textColor = [UIColor whiteColor];
    tv.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    tv.editable = NO;
    tv.scrollEnabled = YES;
    tv.alwaysBounceVertical = YES;
    tv.textContainerInset = UIEdgeInsetsMake(2, 2, 2, 2);
    tv.textContainer.lineFragmentPadding = 0;
    tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [box addSubview:tv];
    self.textView = tv;

    // 文本用 attribute 赋, 保证不经过任何 format 家族
    dispatch_once(&gTextOnce, ^{ gText = [NSMutableString string]; });
    [self renderText];
}

// 按当前 bounds 重新摆面板 (挂载时 host.bounds 可能还是 0)
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *box = self.panelBox;
    if (!box) return;

    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    if (w < 40 || h < 80) return;   // host 还没量好, 下次再说

    CGSize want = CGSizeMake(MIN(340.0, w - 20.0), MIN(320.0, h - 160.0));
    if (want.width < 180) want.width = 180;
    if (want.height < 150) want.height = 150;

    CGRect f = box.frame;
    f.size = want;
    if (!self.boxPositioned) {
        f.origin = CGPointMake(10, 90);
        self.boxPositioned = YES;
        self.panelOrigin = f.origin;
    }
    // 夹回屏内
    if (f.origin.x + f.size.width > w) f.origin.x = MAX(0, w - f.size.width);
    if (f.origin.y + f.size.height > h) f.origin.y = MAX(20, h - f.size.height);
    box.frame = f;
}

- (void)renderText {
    UITextView *tv = self.textView;
    if (!tv) return;
    // ★ 用 NSString 副本赋值; 不要用 stringByAppendingString: 拼可变串
    NSString *snapshot = [NSString stringWithString:(gText ?: @"")];
    tv.text = snapshot;

    // 滚到底
    if (tv.text.length > 0) {
        NSRange r = NSMakeRange(tv.text.length - 1, 1);
        [tv scrollRangeToVisible:r];
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *box = self.panelBox;
    if (!box) return;
    CGPoint t = [g translationInView:self];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragStart = t;
        self.panelOrigin = box.frame.origin;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat nx = self.panelOrigin.x + (t.x - self.dragStart.x);
        CGFloat ny = self.panelOrigin.y + (t.y - self.dragStart.y);
        nx = MAX(0, MIN(self.bounds.size.width - box.bounds.size.width, nx));
        ny = MAX(20, MIN(self.bounds.size.height - 60, ny));
        box.frame = CGRectMake(nx, ny, box.bounds.size.width, box.bounds.size.height);
    }
}

- (void)onClear {
    dispatch_once(&gTextOnce, ^{ gText = [NSMutableString string]; });
    [gText setString:@""];
    [self renderText];
}

- (void)onCopy {
    dispatch_once(&gTextOnce, ^{ gText = [NSMutableString string]; });
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    // 用 NSString 副本, 避免可变串泄漏到剪贴板
    pb.string = [NSString stringWithString:gText];
    NSString *old = self.titleLabel.text;
    self.titleLabel.text = @"已复制 ✓";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self.titleLabel.text = old;
    });
}

@end

#pragma mark - 对外接口

void QEOverlayEnsure(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ QEOverlayEnsure(); });
        return;
    }
    UIWindow *host = QEHostWindow();
    if (!host) return;

    if (!gPanel) {
        gPanel = [[QEOverlayPanel alloc] initWithFrame:host.bounds];
    }
    if (gPanel.superview != host) {
        [gPanel removeFromSuperview];
        gPanel.frame = host.bounds;
        [host addSubview:gPanel];
    } else if (!CGRectEqualToRect(gPanel.frame, host.bounds)) {
        gPanel.frame = host.bounds;
    } else {
        [gPanel setNeedsLayout];
    }
}

void QEOverlayAppend(NSString *title, NSString *body) {
    if (!title || !body) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_once(&gTextOnce, ^{ gText = [NSMutableString string]; });
        QEOverlayEnsure();

        // 纯 appendString, 不经过 format 家族
        [gText appendString:@"【"];
        [gText appendString:title];
        [gText appendString:@"】\n"];
        [gText appendString:body];
        [gText appendString:@"\n\n"];

        // 防无限增长: 超过 200KB 截掉前一半
        if (gText.length > 200000) {
            NSRange cut = NSMakeRange(0, 100000);
            [gText deleteCharactersInRange:cut];
            [gText insertString:@"...(前面已截断)...\n" atIndex:0];
        }

        if (gPanel) [gPanel renderText];
    });
}
