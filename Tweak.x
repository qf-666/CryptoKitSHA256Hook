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
                    requestHits:(long long)requestHits
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
    self.titleLabel.text = @"QE Sign Trace";
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

    [self.rootViewController.view addSubview:self.panelView];
    [self updateStatusWithRawHits:0 shownHits:0 requestHits:0 lastSource:@"Loaded" note:@"ready"];

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
    self.titleLabel.frame = CGRectMake(12.0, 10.0, width - 164.0, 18.0);
    self.statusLabel.frame = CGRectMake(12.0, 29.0, width - 164.0, 28.0);
    self.collapseButton.frame = CGRectMake(width - 138.0, 14.0, 36.0, 36.0);
    self.clipboardButton.frame = CGRectMake(width - 96.0, 14.0, 42.0, 36.0);
    self.clearButton.frame = CGRectMake(width - 48.0, 14.0, 42.0, 36.0);

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
                    requestHits:(long long)requestHits
                     lastSource:(NSString *)lastSource
                           note:(NSString *)note {
    self.statusLabel.text = [NSString stringWithFormat:@"Hash %lld | Show %lld | Req %lld\n%@ | %@",
                             rawHits,
                             shownHits,
                             requestHits,
                             lastSource ?: @"-",
                             note ?: @"-"];
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
static long long gRequestHitCount = 0;
static BOOL gDidLogQiekjRuleSummary = NO;

static NSString *const kQiekjSignTemplate = @"appSecret=%@&channel=%@&timestamp=%@&token=%@&version=%@&%@";
static NSString *const kQiekjSignSecret = @"boPSJlBfm3Ff7Fha1UcLskRNsEOZzyNwQ68c9T/k2UQ=";
static NSString *const kQiekjSignEntryChain = @"QEGetAppSignHybird -> sub_100C524CC/sub_100C5180C -> sub_100C37EB0";
static NSString *const kQiekjSignAlgorithm = @"CryptoKit.SHA256";
static NSString *const kQiekjPathRule = @"strip https://userapi.qiekj.com/ -> drop query -> keep leading slash";

static NSMutableDictionary *incrementalBuffers;
static NSLock *incrementalLock;
static NSMutableDictionary *incrementalHmacBuffers;
static NSMutableDictionary *incrementalHmacKeys;
static NSLock *incrementalHmacLock;
static unsigned char *(*orig_CC_SHA256)(const void *data, CC_LONG len, unsigned char *md);

static NSString *stringFromBytes(const void *bytes, size_t length) {
    if (!bytes || length == 0) {
        return @"<empty>";
    }

    NSData *data = [NSData dataWithBytes:bytes length:length];
    NSString *utf8 = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (utf8.length > 0) {
        return utf8;
    }

    NSUInteger previewLength = MIN((NSUInteger)length, (NSUInteger)48);
    const unsigned char *raw = (const unsigned char *)bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:(previewLength * 2) + 16];
    for (NSUInteger i = 0; i < previewLength; i++) {
        [hex appendFormat:@"%02x", raw[i]];
    }
    if (length > previewLength) {
        [hex appendString:@"..."];
    }
    return [NSString stringWithFormat:@"<hex:%@>", hex];
}

static NSString *digestHexString(const unsigned char *digest, size_t length) {
    if (!digest || length == 0) {
        return @"<no-digest>";
    }

    NSMutableString *hashString = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) {
        [hashString appendFormat:@"%02x", digest[i]];
    }
    return hashString;
}

static NSString *headerValue(NSURLRequest *request, NSString *targetKey) {
    NSDictionary *headers = request.allHTTPHeaderFields ?: @{};
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:targetKey] == NSOrderedSame) {
            id value = headers[key];
            return [value isKindOfClass:[NSString class]] ? (NSString *)value : [value description];
        }
    }
    return nil;
}

static NSDictionary<NSString *, NSString *> *currentUserTokenInfo(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray<NSString *> *candidateKeys = @[@"KUserToken", @"userToken", @"token", @"kUserToken"];
    for (NSString *key in candidateKeys) {
        id value = [defaults objectForKey:key];
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
            return @{
                @"value": (NSString *)value,
                @"source": [NSString stringWithFormat:@"NSUserDefaults[%@]", key]
            };
        }
    }

    NSDictionary *allValues = [defaults dictionaryRepresentation];
    for (NSString *key in allValues) {
        if ([[key lowercaseString] containsString:@"token"]) {
            id value = allValues[key];
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                return @{
                    @"value": (NSString *)value,
                    @"source": [NSString stringWithFormat:@"NSUserDefaults[%@]", key]
                };
            }
        }
    }
    return @{
        @"value": @"",
        @"source": @"NSUserDefaults[token*] missing"
    };
}

static NSDictionary<NSString *, NSString *> *currentAppVersionInfo(void) {
    NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    return @{
        @"value": version ?: @"",
        @"source": @"NSBundle.mainBundle[CFBundleShortVersionString]"
    };
}

static NSString *sha256HexForString(NSString *rawString) {
    if (!rawString) {
        return nil;
    }
    NSData *data = [rawString dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    if (orig_CC_SHA256) {
        orig_CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    } else {
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    }
    return digestHexString(digest, CC_SHA256_DIGEST_LENGTH);
}

static NSString *normalizedQiekjPath(NSURLRequest *request) {
    NSString *absoluteURL = request.URL.absoluteString ?: @"";
    NSString *path = absoluteURL;
    NSString *prefix = @"https://userapi.qiekj.com/";
    NSRange prefixRange = [absoluteURL rangeOfString:prefix options:NSCaseInsensitiveSearch];
    if (prefixRange.location != NSNotFound) {
        NSUInteger start = prefixRange.location + prefixRange.length;
        if (start > 0) {
            start -= 1;
        }
        path = [absoluteURL substringFromIndex:MIN(start, absoluteURL.length)];
    } else {
        path = request.URL.path ?: @"";
    }

    NSRange queryRange = [path rangeOfString:@"?"];
    if (queryRange.location != NSNotFound) {
        path = [path substringToIndex:queryRange.location];
    }

    if (path.length == 0) {
        return nil;
    }
    if (![path hasPrefix:@"/"]) {
        path = [@"/" stringByAppendingString:path];
    }
    return path;
}

static NSDictionary<NSString *, NSString *> *computedQiekjSignInfo(NSURLRequest *request) {
    NSString *host = request.URL.host.lowercaseString ?: @"";
    if (![host containsString:@"qiekj.com"]) {
        return nil;
    }

    NSString *timestamp = headerValue(request, @"timestamp");
    NSString *channel = headerValue(request, @"channel") ?: @"ios_app";
    NSString *version = headerValue(request, @"version");
    NSString *versionSource = @"HTTP header[version]";
    if (version.length == 0) {
        NSDictionary<NSString *, NSString *> *versionInfo = currentAppVersionInfo();
        version = versionInfo[@"value"];
        versionSource = versionInfo[@"source"];
    }
    NSDictionary<NSString *, NSString *> *tokenInfo = currentUserTokenInfo();
    NSString *token = tokenInfo[@"value"];
    NSString *tokenSource = tokenInfo[@"source"];
    NSString *path = normalizedQiekjPath(request);
    NSMutableDictionary<NSString *, NSString *> *info = [@{
        @"algorithm": kQiekjSignAlgorithm,
        @"entryChain": kQiekjSignEntryChain,
        @"template": kQiekjSignTemplate,
        @"secret": kQiekjSignSecret,
        @"pathRule": kQiekjPathRule,
        @"tokenSource": tokenSource ?: @"<unknown>",
        @"versionSource": versionSource ?: @"<unknown>"
    } mutableCopy];

    if (timestamp.length > 0) info[@"timestamp"] = timestamp;
    if (channel.length > 0) info[@"channel"] = channel;
    if (version.length > 0) info[@"version"] = version;
    if (token.length > 0) info[@"token"] = token;
    if (path.length > 0) info[@"path"] = path;

    if (timestamp.length == 0 || channel.length == 0 || version.length == 0 || token.length == 0 || path.length == 0) {
        return info;
    }

    NSString *raw = [NSString stringWithFormat:kQiekjSignTemplate,
                     kQiekjSignSecret,
                     channel,
                     timestamp,
                     token,
                     version,
                     path];
    NSString *sign = sha256HexForString(raw);
    if (!sign) {
        return nil;
    }

    info[@"raw"] = raw;
    info[@"sign"] = sign;
    return info;
}

static void appendLogMessage(NSString *logMessage, NSString *source, NSString *note, long long rawHits);

static void logQiekjRuleSummaryIfNeeded(long long rawHits) {
    if (gDidLogQiekjRuleSummary) {
        return;
    }
    gDidLogQiekjRuleSummary = YES;

    NSString *summary = [NSString stringWithFormat:
                         @"[QE Sign Rule]\n"
                         @"Source: IDA-MCP\n"
                         @"Entry: %@\n"
                         @"Hash: %@\n"
                         @"Template: %@\n"
                         @"Secret: %@\n"
                         @"PathRule: %@\n"
                         @"TokenSource: sub_1004BA88C -> KUserToken\n"
                         @"VersionSource: sub_100079FB8 -> NSBundle.mainBundle -> CFBundleShortVersionString",
                         kQiekjSignEntryChain,
                         kQiekjSignAlgorithm,
                         kQiekjSignTemplate,
                         kQiekjSignSecret,
                         kQiekjPathRule];
    appendLogMessage(summary, @"IDA-MCP", @"qe-rule", rawHits);
}

static void appendLogMessage(NSString *logMessage, NSString *source, NSString *note, long long rawHits) {
    NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *logFilePath = [documentsPath stringByAppendingPathComponent:@"CryptoHook.txt"];
    NSString *fileLogString = [logMessage stringByAppendingString:@"\n\n----------------------------\n"];

    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
    if (!fileHandle) {
        [fileLogString writeToFile:logFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[fileLogString dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }

    long long shownHits = __sync_add_and_fetch(&gShownHookHitCount, 1);
    long long requestHits = __sync_add_and_fetch(&gRequestHitCount, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        SHAFloatingWindow *window = [SHAFloatingWindow shared];
        [window updateStatusWithRawHits:rawHits
                              shownHits:shownHits
                            requestHits:requestHits
                             lastSource:source
                                   note:note];
        [window addLog:[logMessage stringByAppendingFormat:@"\n\n[Saved]\n%@", logFilePath]];
    });
}

static void logInterestingRequest(NSURLRequest *request, NSString *source) {
    if (!request) {
        return;
    }

    NSString *host = request.URL.host.lowercaseString ?: @"";
    NSDictionary *headers = request.allHTTPHeaderFields ?: @{};
    NSString *signValue = headers[@"sign"] ?: headers[@"Sign"] ?: headers[@"SIGN"];
    BOOL interesting = (signValue.length > 0 || [host containsString:@"qiekj.com"]);
    if (!interesting) {
        return;
    }

    long long requestHits = __sync_add_and_fetch(&gRequestHitCount, 1);
    long long rawHits = __sync_add_and_fetch(&gRawHookHitCount, 0);
    logQiekjRuleSummaryIfNeeded(rawHits);

    NSData *bodyData = request.HTTPBody;
    NSString *bodyPreview = bodyData ? stringFromBytes(bodyData.bytes, bodyData.length) : @"<none>";
    if (!bodyData && request.HTTPBodyStream) {
        bodyPreview = @"<HTTPBodyStream>";
    }

    NSDictionary<NSString *, NSString *> *signInfo = computedQiekjSignInfo(request);
    NSString *actualSign = signValue ?: @"<none>";
    NSString *computedSign = signInfo[@"sign"];
    NSString *note = @"request";
    NSMutableString *extra = [NSMutableString string];
    [extra appendString:@"\nRuleSource: IDA-MCP"];
    [extra appendFormat:@"\nEntryChain: %@", signInfo[@"entryChain"] ?: kQiekjSignEntryChain];
    [extra appendFormat:@"\nHashAlgorithm: %@", signInfo[@"algorithm"] ?: kQiekjSignAlgorithm];
    [extra appendFormat:@"\nTemplate: %@", signInfo[@"template"] ?: kQiekjSignTemplate];
    [extra appendFormat:@"\nSecret: %@", signInfo[@"secret"] ?: kQiekjSignSecret];
    [extra appendFormat:@"\nPathRule: %@", signInfo[@"pathRule"] ?: kQiekjPathRule];
    [extra appendFormat:@"\nTokenSource: %@", signInfo[@"tokenSource"] ?: @"<unknown>"];
    [extra appendFormat:@"\nVersionSource: %@", signInfo[@"versionSource"] ?: @"<unknown>"];
    if (computedSign.length > 0) {
        BOOL matched = [computedSign caseInsensitiveCompare:actualSign] == NSOrderedSame;
        note = matched ? @"sign-ok" : @"sign-miss";
        [extra appendFormat:@"\nComputedSign: %@", computedSign];
        [extra appendFormat:@"\nSignMatch: %@", matched ? @"YES" : @"NO"];
        [extra appendFormat:@"\nPath: %@", signInfo[@"path"] ?: @"<nil>"];
        [extra appendFormat:@"\nTimestamp: %@", signInfo[@"timestamp"] ?: @"<nil>"];
        [extra appendFormat:@"\nVersion: %@", signInfo[@"version"] ?: @"<nil>"];
        [extra appendFormat:@"\nToken: %@", signInfo[@"token"] ?: @"<nil>"];
        [extra appendFormat:@"\nRaw: %@", signInfo[@"raw"] ?: @"<nil>"];
    } else if (signInfo.count > 0) {
        note = @"need-token";
        [extra appendFormat:@"\nPartialInfo: %@", signInfo];
    }

    NSString *logMessage = [NSString stringWithFormat:@"[Request %@ #%lld]\n%@ %@\nHost: %@\nHeaders: %@\nBody: %@\nActualSign: %@%@",
                            source,
                            requestHits,
                            request.HTTPMethod ?: @"GET",
                            request.URL.absoluteString ?: @"<nil-url>",
                            host.length > 0 ? host : @"<nil-host>",
                            headers,
                            bodyPreview,
                            actualSign,
                            extra];

    NSLog(@"[SHA256_HOOK_REQUEST]\n%@", logMessage);
    appendLogMessage(logMessage, source, note, rawHits);
}

static void process_sha256(const void *data, size_t len, unsigned char *digest, NSString *source) {
    if (!data || !digest) {
        return;
    }

    long long rawHits = __sync_add_and_fetch(&gRawHookHitCount, 1);
    long long requestHits = __sync_add_and_fetch(&gRequestHitCount, 0);
    NSString *inputString = stringFromBytes(data, len);
    BOOL keywordMatch = ([inputString containsString:@"appSecret="] ||
                         [inputString containsString:@"qiekj.com"]);
    BOOL debugSample = (rawHits <= 12);
    BOOL passesDisplayFilter = keywordMatch || debugSample;
    long long shownHitsSnapshot = __sync_add_and_fetch(&gShownHookHitCount, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SHAFloatingWindow shared] updateStatusWithRawHits:rawHits
                                                  shownHits:shownHitsSnapshot
                                                requestHits:requestHits
                                                 lastSource:source
                                                       note:(keywordMatch ? @"matched" : (debugSample ? @"sample" : @"filtered"))];
    });

    if (!passesDisplayFilter) {
        return;
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
                            digestHexString(digest, 32),
                            [filteredStack componentsJoinedByString:@"\n"]];

    NSLog(@"[SHA256_HOOK]\n%@", logMessage);
    appendLogMessage(logMessage, source, (keywordMatch ? @"shown" : @"sample"), rawHits);
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

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
    logInterestingRequest(request, @"NSURLSession");
    return %orig;
}

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    logInterestingRequest(request, @"NSURLSession");
    return %orig;
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *data, NSURLResponse *response, NSError *error))completionHandler {
    NSMutableURLRequest *mutableRequest = [request mutableCopy];
    if (bodyData.length > 0 && !mutableRequest.HTTPBody) {
        mutableRequest.HTTPBody = bodyData;
    }
    logInterestingRequest(mutableRequest ?: request, @"NSURLUpload");
    return %orig;
}

%end

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
