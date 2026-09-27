#import <UIKit/UIKit.h>
#import <substrate.h>
#import <CommonCrypto/CommonCrypto.h>
#import "fishhook.h"

// ---------------------------------------------------------------- overlay ---
// Deliberately NOT a UIWindow subclass. Creating our own UIWindow on iOS 16
// while the host app's scene is still settling produced repeated SIGBUS
// ("Address size fault") inside our own layout code, because a window that is
// not attached to a live UIWindowScene has undefined bounds. Instead we hang a
// plain UIView off whatever window the host app already owns and is displaying.
@interface SHAOverlayView : UIView
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *clipboardButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UIButton *collapseButton;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, assign) BOOL collapsed;
@property (nonatomic, assign) CGPoint dragStartOrigin;
@property (nonatomic, assign) CGFloat expandedHeight;
+ (instancetype)shared;
- (void)addLog:(NSString *)log;
- (void)updateStatusWithRawHits:(long long)rawHits
                      shownHits:(long long)shownHits
                       utf8Hits:(long long)utf8Hits
                     lastSource:(NSString *)lastSource
                           note:(NSString *)note;
@end

@implementation SHAOverlayView

// Find a window that actually exists and is on screen. Returns nil when the
// host app has not finished building its UI yet; callers must tolerate that and
// retry later.
+ (UIWindow *)hostWindow {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        return nil;
    }

    UIWindow *fallback = app.delegate.window;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }
            for (UIWindow *w in windowScene.windows) {
                if (w.isKeyWindow && w.windowLevel == UIWindowLevelNormal) {
                    return w;
                }
            }
            for (UIWindow *w in windowScene.windows) {
                if (w.windowLevel == UIWindowLevelNormal) {
                    return w;
                }
            }
        }
    }
    if (fallback && fallback.windowLevel == UIWindowLevelNormal) {
        return fallback;
    }
    return nil;
}

+ (instancetype)shared {
    static SHAOverlayView *view = nil;
    static dispatch_once_t onceToken;

    UIWindow *host = [self hostWindow];
    if (!host) {
        return nil;
    }

    dispatch_once(&onceToken, ^{
        view = [[self alloc] initWithFrame:host.bounds];
        [view commonInit];
    });

    // Re-attach if the host window changed (rotation, app switch, scene swap).
    if (view.superview != host) {
        [view removeFromSuperview];
        view.frame = host.bounds;
        [host addSubview:view];
    } else if (!CGRectEqualToRect(view.frame, host.bounds)) {
        view.frame = host.bounds;
    }
    [view setNeedsLayout];
    return view;
}

- (CGRect)defaultPanelFrame {
    CGRect bounds = self.bounds;
    if (CGRectIsEmpty(bounds)) {
        bounds = CGRectMake(0.0, 0.0, 390.0, 844.0);
    }
    CGFloat availableWidth = MAX(220.0, CGRectGetWidth(bounds) - 24.0);
    CGFloat panelWidth = MIN(340.0, availableWidth);
    CGFloat panelHeight = MIN(300.0, MAX(190.0, CGRectGetHeight(bounds) - 180.0));
    return CGRectMake(12.0, 90.0, panelWidth, panelHeight);
}

- (void)commonInit {
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.expandedHeight = CGRectGetHeight([self defaultPanelFrame]);

    self.panelView = [[UIView alloc] initWithFrame:[self defaultPanelFrame]];
    self.panelView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    self.panelView.layer.cornerRadius = 14.0;
    self.panelView.layer.borderWidth = 1.0;
    self.panelView.layer.borderColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.4].CGColor;
    self.panelView.clipsToBounds = YES;
    self.panelView.autoresizingMask = UIViewAutoresizingNone;
    [self addSubview:self.panelView];

    self.headerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.headerView.backgroundColor = [[UIColor colorWithRed:0.09 green:0.12 blue:0.10 alpha:0.95] colorWithAlphaComponent:0.95];
    [self.panelView addSubview:self.headerView];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    [self.headerView addGestureRecognizer:pan];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = @"SHA256 Blind Trace";
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.font = [UIFont boldSystemFontOfSize:13.0];
    [self.headerView addSubview:self.titleLabel];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.statusLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.72];
    self.statusLabel.font = [UIFont systemFontOfSize:10.0];
    self.statusLabel.numberOfLines = 2;
    [self.headerView addSubview:self.statusLabel];

    self.collapseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.collapseButton setTitle:@"-" forState:UIControlStateNormal];
    [self.collapseButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.collapseButton.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
    self.collapseButton.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.85];
    self.collapseButton.layer.cornerRadius = 9.0;
    [self.collapseButton addTarget:self action:@selector(toggleCollapsed) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.collapseButton];

    self.clearButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clearButton setTitle:@"Clear" forState:UIControlStateNormal];
    [self.clearButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.clearButton.titleLabel.font = [UIFont boldSystemFontOfSize:11.0];
    self.clearButton.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.85];
    self.clearButton.layer.cornerRadius = 9.0;
    [self.clearButton addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.clearButton];

    self.clipboardButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clipboardButton setTitle:@"Copy" forState:UIControlStateNormal];
    [self.clipboardButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.clipboardButton.titleLabel.font = [UIFont boldSystemFontOfSize:11.0];
    self.clipboardButton.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.85];
    self.clipboardButton.layer.cornerRadius = 9.0;
    [self.clipboardButton addTarget:self action:@selector(copyLogs) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:self.clipboardButton];

    self.textView = [[UITextView alloc] initWithFrame:CGRectZero];
    self.textView.backgroundColor = [UIColor clearColor];
    self.textView.textColor = [UIColor systemGreenColor];
    self.textView.font = [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular];
    self.textView.editable = NO;
    self.textView.selectable = YES;
    self.textView.alwaysBounceVertical = YES;
    self.textView.showsVerticalScrollIndicator = YES;
    self.textView.textContainerInset = UIEdgeInsetsMake(6, 4, 8, 4);
    [self.panelView addSubview:self.textView];

    [self updateStatusWithRawHits:0 shownHits:0 utf8Hits:0 lastSource:@"Loaded" note:@"ready"];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    if (CGRectIsEmpty(self.bounds)) {
        return;
    }

    if (CGRectEqualToRect(self.panelView.frame, CGRectZero)) {
        self.panelView.frame = [self defaultPanelFrame];
    }

    CGRect panelFrame = self.panelView.frame;
    CGFloat availableWidth = MAX(220.0, CGRectGetWidth(self.bounds) - 24.0);
    panelFrame.size.width = MIN(panelFrame.size.width, availableWidth);
    panelFrame.size.height = self.collapsed ? 66.0 : MIN(MAX(self.expandedHeight, 190.0), CGRectGetHeight(self.bounds) - 40.0);
    self.panelView.frame = panelFrame;
    [self clampPanelFrame];

    CGFloat width = CGRectGetWidth(self.panelView.bounds);
    self.headerView.frame = CGRectMake(0.0, 0.0, width, 66.0);
    self.titleLabel.frame = CGRectMake(12.0, 10.0, MAX(20.0, width - 164.0), 18.0);
    self.statusLabel.frame = CGRectMake(12.0, 29.0, MAX(20.0, width - 164.0), 28.0);
    self.collapseButton.frame = CGRectMake(width - 138.0, 14.0, 36.0, 36.0);
    self.clipboardButton.frame = CGRectMake(width - 96.0, 14.0, 42.0, 36.0);
    self.clearButton.frame = CGRectMake(width - 48.0, 14.0, 42.0, 36.0);

    self.textView.hidden = self.collapsed;
    if (!self.collapsed) {
        CGFloat tvWidth = MAX(100.0, CGRectGetWidth(self.panelView.bounds) - 16.0);
        CGFloat tvHeight = MAX(40.0, CGRectGetHeight(self.panelView.bounds) - CGRectGetMaxY(self.headerView.frame) - 8.0);
        self.textView.frame = CGRectMake(8.0, CGRectGetMaxY(self.headerView.frame), tvWidth, tvHeight);
    }
}

- (void)clampPanelFrame {
    CGRect frame = self.panelView.frame;
    CGFloat minX = 8.0;
    CGFloat minY = 48.0;
    CGFloat maxX = MAX(minX, CGRectGetWidth(self.bounds) - CGRectGetWidth(frame) - 8.0);
    CGFloat maxY = MAX(minY, CGRectGetHeight(self.bounds) - CGRectGetHeight(frame) - 8.0);
    frame.origin.x = MIN(MAX(frame.origin.x, minX), maxX);
    frame.origin.y = MIN(MAX(frame.origin.y, minY), maxY);
    self.panelView.frame = frame;
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)gesture {
    CGPoint translation = [gesture translationInView:self];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragStartOrigin = self.panelView.frame.origin;
    }

    CGRect frame = self.panelView.frame;
    frame.origin.x = self.dragStartOrigin.x + translation.x;
    frame.origin.y = self.dragStartOrigin.y + translation.y;
    self.panelView.frame = frame;
    [self clampPanelFrame];
}

- (void)toggleCollapsed {
    self.collapsed = !self.collapsed;
    [self.collapseButton setTitle:(self.collapsed ? @"+" : @"-") forState:UIControlStateNormal];
    if (!self.collapsed) {
        self.expandedHeight = MAX(self.expandedHeight, 220.0);
    }

    [UIView animateWithDuration:0.2 animations:^{
        CGRect frame = self.panelView.frame;
        if (self.collapsed) {
            self.expandedHeight = MAX(frame.size.height, 220.0);
            frame.size.height = 66.0;
        } else {
            frame.size.height = self.expandedHeight;
        }
        self.panelView.frame = frame;
        [self setNeedsLayout];
        [self layoutIfNeeded];
    }];
}

- (void)clearLogs {
    self.textView.text = @"";
}

- (void)copyLogs {
    NSString *fullText = self.textView.text ?: @"";
    [UIPasteboard generalPasteboard].string = fullText;

    NSString *oldTitle = [self.clipboardButton titleForState:UIControlStateNormal];
    [self.clipboardButton setTitle:@"Done" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.clipboardButton setTitle:(oldTitle ?: @"Copy") forState:UIControlStateNormal];
    });
}

- (void)addLog:(NSString *)log {
    if (!self.textView) {
        return;
    }
    self.textView.text = [NSString stringWithFormat:@"%@\n\n%@", log, self.textView.text ?: @""];
}

- (void)updateStatusWithRawHits:(long long)rawHits
                      shownHits:(long long)shownHits
                       utf8Hits:(long long)utf8Hits
                     lastSource:(NSString *)lastSource
                           note:(NSString *)note {
    self.statusLabel.text = [NSString stringWithFormat:@"Hook %lld | Show %lld | UTF8 %lld\n%@ | %@",
                             rawHits,
                             shownHits,
                             utf8Hits,
                             lastSource ?: @"-",
                             note ?: @"-"];
}

// Only the panel area should swallow touches; everywhere else stays pass-through
// for the host app.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) {
        return nil;
    }
    CGPoint pointInPanel = [self convertPoint:point toView:self.panelView];
    if (!CGRectContainsPoint(self.panelView.bounds, pointInPanel)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end
