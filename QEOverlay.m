// QEOverlay.m
// ---------------------------------------------------------------------------
// 精简悬浮窗实现。设计要点:
//   1. 绝不 hook 任何系统方法, 只用公开 API (addSubview 到宿主 window)
//   2. 所有 UI 操作强制在主线程, 且用 dispatch_async 避免在系统路径里同步阻塞
//   3. 文本只追加到 UITextView, 不调用任何可能重入 format hook 的路径
//      (UITextView.text 赋值走的是自己的存储, 不经过 NSString format 家族)
//   4. 面板可拖动, 有清空/复制按钮
// ---------------------------------------------------------------------------

#import "QEOverlay.h"

@interface QEOverlayPanel : UIView
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIView *panelBox;   // 面板盒子 (拖动目标)
@property (nonatomic, assign) CGPoint dragStart;
@property (nonatomic, assign) CGPoint panelOrigin;
@end

static QEOverlayPanel *gPanel = nil;
static UIView *gHost = nil;

#pragma mark - 找宿主 window (与 Tweak.x 同策略, 只看 UIWindowScene)

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

    UIView *box = [[UIView alloc] initWithFrame:CGRectMake(10, 80, MIN(340, self.bounds.size.width - 20), 260)];
    box.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    box.layer.cornerRadius = 12.0;
    box.layer.borderWidth = 1.0;
    box.layer.borderColor = [green colorWithAlphaComponent:0.5].CGColor;
    box.clipsToBounds = YES;
    box.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self addSubview:box];
    self.panelOrigin = box.frame.origin;

    // 标题栏 (兼拖动把手)
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, box.bounds.size.width, 28)];
    bar.backgroundColor = [green colorWithAlphaComponent:0.22];
    [box addSubview:bar];

    UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, box.bounds.size.width - 100, 28)];
    lbl.text = @"QE_SIGN_HOOK";
    lbl.font = [UIFont boldSystemFontOfSize:12];
    lbl.textColor = green;
    [bar addSubview:lbl];
    self.titleLabel = lbl;

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    clear.frame = CGRectMake(box.bounds.size.width - 90, 2, 40, 24);
    [clear setTitle:@"清空" forState:UIControlStateNormal];
    clear.titleLabel.font = [UIFont systemFontOfSize:12];
    [clear addTarget:self action:@selector(onClear) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:clear];

    UIButton *copy = [UIButton buttonWithType:UIButtonTypeSystem];
    copy.frame = CGRectMake(box.bounds.size.width - 46, 2, 40, 24);
    [copy setTitle:@"复制" forState:UIControlStateNormal];
    copy.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [copy addTarget:self action:@selector(onCopy) forControlEvents:UIControlEventTouchUpInside];
    [bar addSubview:copy];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [bar addGestureRecognizer:pan];

    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(6, 32, box.bounds.size.width - 12, box.bounds.size.height - 38)];
    tv.backgroundColor = [UIColor clearColor];
    tv.textColor = [UIColor whiteColor];
    tv.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    tv.editable = NO;
    tv.scrollEnabled = YES;
    tv.text = @"等待签名...\n";
    [box addSubview:tv];
    self.textView = tv;

    self.panelBox = box;
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *box = self.panelBox;
    if (!box) return;
    CGPoint t = [g translationInView:self];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragStart = t;
        self.panelOrigin = box.frame.origin;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint p = CGPointMake(self.panelOrigin.x + (t.x - self.dragStart.x),
                                self.panelOrigin.y + (t.y - self.dragStart.y));
        p.x = MAX(0, MIN(self.bounds.size.width - box.bounds.size.width, p.x));
        p.y = MAX(20, MIN(self.bounds.size.height - 60, p.y));
        box.frame = CGRectMake(p.x, p.y, box.bounds.size.width, box.bounds.size.height);
    }
}

- (void)onClear {
    self.textView.text = @"";
}

- (void)onCopy {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    pb.string = self.textView.text ?: @"";
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
    if (!host) return;   // UI 还没建好, 下次再来

    if (!gPanel) {
        gPanel = [[QEOverlayPanel alloc] initWithFrame:host.bounds];
    }
    if (gPanel.superview != host) {
        [gPanel removeFromSuperview];
        gPanel.frame = host.bounds;
        [host addSubview:gPanel];
    } else if (!CGRectEqualToRect(gPanel.frame, host.bounds)) {
        gPanel.frame = host.bounds;
    }
    gHost = host;
}

void QEOverlayAppend(NSString *title, NSString *body) {
    if (!title || !body) return;
    // ★ 必须异步: 我们可能在系统哈希/description 路径里被调用,
    //   同步做 UI 会在这条路径上引入额外对象创建与锁, 重蹈 mutateError
    dispatch_async(dispatch_get_main_queue(), ^{
        QEOverlayEnsure();
        if (!gPanel) return;
        // 手动拼接, 不用 stringWithFormat (避免重入 format hook)
        NSMutableString *s = [NSMutableString stringWithCapacity:body.length + 64];
        [s appendString:@"["];
        [s appendString:title];
        [s appendString:@"]  "];
        [s appendString:body];
        [s appendString:@"\n\n"];

        UITextView *tv = gPanel.textView;
        NSString *old = tv.text ?: @"";
        if (old.length > 40000) old = @"";   // 防无限增长
        tv.text = [old stringByAppendingString:s];
        // 滚到底
        NSRange r = NSMakeRange(tv.text.length, 0);
        [tv scrollRangeToVisible:r];
    });
}
