#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <CommonCrypto/CommonCrypto.h>
#import "fishhook.h"

@interface SHAFloatingWindow : UIWindow
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIView *headerView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
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
                     lastSource:(NSString *)lastSource
                           note:(NSString *)note;
@end

@implementation SHAFloatingWindow

+ (UIWindowScene *)bestScene {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *fallbackScene = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            if (!fallbackScene) {
                fallbackScene = windowScene;
            }
            if (scene.activationState == UISceneActivationStateForegroundActive ||
                scene.activationState == UISceneActivationStateForegroundInactive) {
                return windowScene;
            }
        }
        return fallbackScene;
    }
    return nil;
}

+ (instancetype)shared {
    static SHAFloatingWindow *win = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIWindowScene *scene = [self bestScene];
        if (@available(iOS 13.0, *)) {
            if (scene) {
                win = [[self alloc] initWithWindowScene:scene];
            } else {
                win = [[self alloc] initWithFrame:[UIScreen mainScreen].bounds];
            }
        } else {
            win = [[self alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        [win commonInit];
    });
    [win attachToBestSceneIfNeeded];
    return win;
}

- (CGRect)defaultPanelFrame {
    CGFloat availableWidth = MAX(220.0, CGRectGetWidth(self.bounds) - 24.0);
    CGFloat panelWidth = MIN(340.0, availableWidth);
    CGFloat panelHeight = MIN(300.0, MAX(190.0, CGRectGetHeight(self.bounds) - 180.0));
    return CGRectMake(12.0, 90.0, panelWidth, panelHeight);
}

- (void)commonInit {
    self.frame = [UIScreen mainScreen].bounds;
    self.windowLevel = UIWindowLevelAlert + 1000;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = YES;
    self.expandedHeight = CGRectGetHeight([self defaultPanelFrame]);

    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = [UIColor clearColor];
    self.rootViewController = rootVC;

    self.panelView = [[UIView alloc] initWithFrame:[self defaultPanelFrame]];
    self.panelView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    self.panelView.layer.cornerRadius = 14.0;
    self.panelView.layer.borderWidth = 1.0;
    self.panelView.layer.borderColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.4].CGColor;
    self.panelView.clipsToBounds = YES;

    self.headerView = [[UIView alloc] initWithFrame:CGRectZero];
    self.headerView.backgroundColor = [[UIColor colorWithRed:0.09 green:0.12 blue:0.10 alpha:0.95] colorWithAlphaComponent:0.95];
    [self.panelView addSubview:self.headerView];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
    [self.headerView addGestureRecognizer:pan];

    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.text = @"SHA256 Hook";
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

    [self.rootViewController.view addSubview:self.panelView];
    [self updateStatusWithRawHits:0 shownHits:0 lastSource:@"Loaded" note:@"ready"];

    self.hidden = NO;
    [self setNeedsLayout];
}

- (void)attachToBestSceneIfNeeded {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [SHAFloatingWindow bestScene];
        if (scene && self.windowScene != scene) {
            self.windowScene = scene;
        }
    }
    self.frame = [UIScreen mainScreen].bounds;
    self.hidden = NO;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    self.frame = [UIScreen mainScreen].bounds;
    self.rootViewController.view.frame = self.bounds;

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
    self.titleLabel.frame = CGRectMake(12.0, 10.0, width - 112.0, 18.0);
    self.statusLabel.frame = CGRectMake(12.0, 29.0, width - 112.0, 28.0);
    self.collapseButton.frame = CGRectMake(width - 96.0, 14.0, 36.0, 36.0);
    self.clearButton.frame = CGRectMake(width - 54.0, 14.0, 42.0, 36.0);

    self.textView.hidden = self.collapsed;
    if (!self.collapsed) {
        self.textView.frame = CGRectMake(8.0,
                                         CGRectGetMaxY(self.headerView.frame),
                                         width - 16.0,
                                         CGRectGetHeight(self.panelView.bounds) - CGRectGetMaxY(self.headerView.frame) - 8.0);
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
    CGPoint translation = [gesture translationInView:self.rootViewController.view];
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

- (void)addLog:(NSString *)log {
    if (!self.textView) {
        return;
    }
    self.textView.text = [NSString stringWithFormat:@"%@\n\n%@", log, self.textView.text ?: @""];
}

- (void)updateStatusWithRawHits:(long long)rawHits
                      shownHits:(long long)shownHits
                     lastSource:(NSString *)lastSource
                           note:(NSString *)note {
    self.statusLabel.text = [NSString stringWithFormat:@"Raw %lld | Show %lld\n%@ | %@", rawHits, shownHits, lastSource ?: @"-", note ?: @"-"];
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    CGPoint pointInPanel = [self convertPoint:point toView:self.panelView];
    if (!CGRectContainsPoint(self.panelView.bounds, pointInPanel)) {
        return nil;
    }
    return [super hitTest:point withEvent:event];
}

@end

static long long gRawHookHitCount = 0;
static long long gShownHookHitCount = 0;

static NSMutableDictionary *incrementalBuffers;
static NSLock *incrementalLock;

static void process_sha256(const void *data, size_t len, unsigned char *digest, NSString *source) {
    if (!data || !digest) {
        return;
    }

    long long rawHits = __sync_add_and_fetch(&gRawHookHitCount, 1);

    NSData *inputData = [NSData dataWithBytes:data length:len];
    NSString *inputString = [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding];
    if (!inputString) {
        inputString = [NSString stringWithFormat:@"<Binary Data: %zu bytes>", len];
    }

    BOOL passesKeywordFilter = ([inputString containsString:@"appSecret="] ||
                                [inputString containsString:@"qiekj.com"]);

    long long shownHitsSnapshot = __sync_add_and_fetch(&gShownHookHitCount, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SHAFloatingWindow shared] updateStatusWithRawHits:rawHits
                                                  shownHits:shownHitsSnapshot
                                                 lastSource:source
                                                       note:(passesKeywordFilter ? @"matched" : @"filtered")];
    });

    if (!passesKeywordFilter) {
        return;
    }

    NSMutableString *hashString = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < 32; i++) {
        [hashString appendFormat:@"%02x", digest[i]];
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown.bundle";
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];

    NSArray *stack = [NSThread callStackSymbols];
    NSMutableArray *filteredStack = [NSMutableArray array];
    for (NSString *line in stack) {
        if ([line containsString:@"libsystem"] ||
            [line containsString:@"libdispatch"] ||
            [line containsString:@"corecrypto"] ||
            [line containsString:@"CydiaSubstrate"] ||
            [line containsString:@"CryptoKit"] ||
            [line containsString:@"Tweak"]) {
            continue;
        }
        [filteredStack addObject:line];
    }

    NSString *logMessage = [NSString stringWithFormat:@"[%@]\nTime: %.3f\nBundle: %@\nInput: %@\nHash: %@\nStack:\n%@",
                            source,
                            timestamp,
                            bundleId,
                            inputString,
                            hashString,
                            [filteredStack componentsJoinedByString:@"\n"]];

    NSLog(@"[SHA256_HOOK]\n%@", logMessage);

    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *logFilePath = [documentsPath stringByAppendingPathComponent:@"CryptoHook.txt"];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
    NSString *fileLogString = [logMessage stringByAppendingString:@"\n\n----------------------------\n"];
    if (!fileHandle) {
        [fileLogString writeToFile:logFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[fileLogString dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }

    long long shownHits = __sync_add_and_fetch(&gShownHookHitCount, 1);
    dispatch_async(dispatch_get_main_queue(), ^{
        SHAFloatingWindow *window = [SHAFloatingWindow shared];
        [window updateStatusWithRawHits:rawHits shownHits:shownHits lastSource:source note:@"shown"];
        [window addLog:[logMessage stringByAppendingFormat:@"\n\n[Saved]\n%@", logFilePath]];
    });
}

struct ccdigest_info {
    size_t output_size;
    size_t state_size;
    size_t block_size;
    size_t oid_size;
    unsigned char *oid;
    void *initial_state;
    void *compress;
    void *final;
};

static void (*orig_ccdigest)(const struct ccdigest_info *di, size_t len, const void *data, void *digest);
static void my_ccdigest(const struct ccdigest_info *di, size_t len, const void *data, void *digest) {
    orig_ccdigest(di, len, data, digest);
    if (di && di->output_size == 32) {
        process_sha256(data, len, (unsigned char *)digest, @"ccdigest");
    }
}

static void (*orig_ccdigest_init)(const struct ccdigest_info *di, void *ctx);
static void my_ccdigest_init(const struct ccdigest_info *di, void *ctx) {
    orig_ccdigest_init(di, ctx);
    if (di && di->output_size == 32) {
        [incrementalLock lock];
        incrementalBuffers[[NSValue valueWithPointer:ctx]] = [NSMutableData data];
        [incrementalLock unlock];
    }
}

static void (*orig_ccdigest_update)(const struct ccdigest_info *di, void *ctx, size_t len, const void *data);
static void my_ccdigest_update(const struct ccdigest_info *di, void *ctx, size_t len, const void *data) {
    orig_ccdigest_update(di, ctx, len, data);
    if (di && di->output_size == 32 && len > 0 && data) {
        [incrementalLock lock];
        NSMutableData *buffer = incrementalBuffers[[NSValue valueWithPointer:ctx]];
        if (buffer) {
            [buffer appendBytes:data length:len];
        }
        [incrementalLock unlock];
    }
}

static void (*orig_ccdigest_final)(const struct ccdigest_info *di, void *ctx, unsigned char *digest);
static void my_ccdigest_final(const struct ccdigest_info *di, void *ctx, unsigned char *digest) {
    orig_ccdigest_final(di, ctx, digest);
    if (di && di->output_size == 32) {
        [incrementalLock lock];
        NSValue *key = [NSValue valueWithPointer:ctx];
        NSMutableData *buffer = incrementalBuffers[key];
        NSData *finalData = nil;
        if (buffer) {
            finalData = [buffer copy];
            [incrementalBuffers removeObjectForKey:key];
        }
        [incrementalLock unlock];
        if (finalData) {
            process_sha256(finalData.bytes, finalData.length, digest, @"ccdigest_incremental");
        }
    }
}

static unsigned char *(*orig_CC_SHA256)(const void *data, CC_LONG len, unsigned char *md);
static unsigned char *my_CC_SHA256(const void *data, CC_LONG len, unsigned char *md) {
    unsigned char *ret = orig_CC_SHA256(data, len, md);
    if (ret) {
        process_sha256(data, len, ret, @"CC_SHA256");
    }
    return ret;
}

static int (*orig_CC_SHA256_Init)(CC_SHA256_CTX *c);
static int my_CC_SHA256_Init(CC_SHA256_CTX *c) {
    int ret = orig_CC_SHA256_Init(c);
    if (c) {
        [incrementalLock lock];
        incrementalBuffers[[NSValue valueWithPointer:c]] = [NSMutableData data];
        [incrementalLock unlock];
    }
    return ret;
}

static int (*orig_CC_SHA256_Update)(CC_SHA256_CTX *c, const void *data, CC_LONG len);
static int my_CC_SHA256_Update(CC_SHA256_CTX *c, const void *data, CC_LONG len) {
    int ret = orig_CC_SHA256_Update(c, data, len);
    if (c && len > 0 && data) {
        [incrementalLock lock];
        NSMutableData *buffer = incrementalBuffers[[NSValue valueWithPointer:c]];
        if (buffer) {
            [buffer appendBytes:data length:len];
        }
        [incrementalLock unlock];
    }
    return ret;
}

static int (*orig_CC_SHA256_Final)(unsigned char *md, CC_SHA256_CTX *c);
static int my_CC_SHA256_Final(unsigned char *md, CC_SHA256_CTX *c) {
    int ret = orig_CC_SHA256_Final(md, c);
    [incrementalLock lock];
    NSValue *key = [NSValue valueWithPointer:c];
    NSMutableData *buffer = incrementalBuffers[key];
    NSData *finalData = nil;
    if (buffer) {
        finalData = [buffer copy];
        [incrementalBuffers removeObjectForKey:key];
    }
    [incrementalLock unlock];

    if (finalData) {
        process_sha256(finalData.bytes, finalData.length, md, @"CC_SHA256_Incremental");
    }
    return ret;
}

static void (*orig_cryptokit_sha256)(void *a, void *b, void *c);
static void my_cryptokit_sha256(void *a, void *b, void *c) {
    NSLog(@"[SHA256_HOOK] Hit Swift CryptoKit.SHA256 wrapper");
    orig_cryptokit_sha256(a, b, c);
}

%ctor {
    incrementalBuffers = [NSMutableDictionary dictionary];
    incrementalLock = [[NSLock alloc] init];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
        [SHAFloatingWindow shared];
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
        [SHAFloatingWindow shared];
    }];

    if (@available(iOS 13.0, *)) {
        [center addObserverForName:UISceneDidActivateNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
            [SHAFloatingWindow shared];
        }];
        [center addObserverForName:UISceneWillEnterForegroundNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) {
            [SHAFloatingWindow shared];
        }];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [SHAFloatingWindow shared];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [SHAFloatingWindow shared];
        });
    });

    struct rebinding corecryptoBindings[] = {
        {"ccdigest", (void *)my_ccdigest, (void **)&orig_ccdigest},
        {"ccdigest_init", (void *)my_ccdigest_init, (void **)&orig_ccdigest_init},
        {"ccdigest_update", (void *)my_ccdigest_update, (void **)&orig_ccdigest_update},
        {"ccdigest_final", (void *)my_ccdigest_final, (void **)&orig_ccdigest_final},
    };
    rebind_symbols(corecryptoBindings, sizeof(corecryptoBindings) / sizeof(corecryptoBindings[0]));

    struct rebinding commonCryptoBindings[] = {
        {"CC_SHA256", (void *)my_CC_SHA256, (void **)&orig_CC_SHA256},
        {"CC_SHA256_Init", (void *)my_CC_SHA256_Init, (void **)&orig_CC_SHA256_Init},
        {"CC_SHA256_Update", (void *)my_CC_SHA256_Update, (void **)&orig_CC_SHA256_Update},
        {"CC_SHA256_Final", (void *)my_CC_SHA256_Final, (void **)&orig_CC_SHA256_Final},
    };
    rebind_symbols(commonCryptoBindings, sizeof(commonCryptoBindings) / sizeof(commonCryptoBindings[0]));

    MSImageRef cryptoKitRef = MSGetImageByName("/System/Library/Frameworks/CryptoKit.framework/CryptoKit");
    if (cryptoKitRef) {
        void *swiftHashSym = MSFindSymbol(cryptoKitRef, "_$s9CryptoKit6SHA256V4hash4dataAA0C6DigestVcx_tc10Foundation12DataProtocolRzlFZ");
        if (swiftHashSym) {
            MSHookFunction((void *)swiftHashSym, (void *)my_cryptokit_sha256, (void **)&orig_cryptokit_sha256);
        }
    }
}
