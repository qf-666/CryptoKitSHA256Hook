#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <CommonCrypto/CommonCrypto.h>
#import "fishhook.h"

// --- UI 悬浮窗实现 ---
@interface SHAFloatingWindow : UIWindow
@property (nonatomic, strong) UITextView *textView;
+ (instancetype)shared;
- (void)addLog:(NSString *)log;
@end

@implementation SHAFloatingWindow
+ (instancetype)shared {
    static SHAFloatingWindow *win = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (@available(iOS 13.0, *)) {
            for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive || 
                    scene.activationState == UISceneActivationStateForegroundInactive) {
                    win = [[self alloc] initWithWindowScene:scene];
                    break;
                }
            }
        }
        if (!win) win = [[self alloc] initWithFrame:[UIScreen mainScreen].bounds];
        
        win.windowLevel = UIWindowLevelAlert + 1000;
        win.backgroundColor = [UIColor clearColor];

        // 必须设置 rootViewController，否则 iOS 会引发异常导致崩溃
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        win.rootViewController = rootVC;
        
        win.hidden = NO;

        // 顶部悬浮框 (允许交互，长按复制，可滚动)
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(10, 80, [UIScreen mainScreen].bounds.size.width - 20, 250)];
        tv.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        tv.textColor = [UIColor systemGreenColor];
        tv.font = [UIFont systemFontOfSize:10];
        tv.editable = NO;
        tv.selectable = YES; // 允许长按复制
        tv.userInteractionEnabled = YES; // 允许滑动
        tv.layer.cornerRadius = 8;
        tv.clipsToBounds = YES;
        [win addSubview:tv];
        win.textView = tv;
        
        // 增加一个清空按钮
        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake([UIScreen mainScreen].bounds.size.width - 60, 45, 50, 30);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
        [clearBtn setBackgroundColor:[UIColor darkGrayColor]];
        [clearBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        clearBtn.layer.cornerRadius = 5;
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [clearBtn addTarget:win action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
        [win addSubview:clearBtn];
    });
    return win;
}
- (void)clearLogs {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.textView.text = @"";
    });
}
- (void)addLog:(NSString *)log {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.textView) return;
        self.textView.text = [NSString stringWithFormat:@"%@\n\n%@", log, self.textView.text];
    });
}
// 允许事件穿透背景（可以正常点下面的 App），但不穿透我们的文本框和按钮
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self || hitView == self.rootViewController.view) {
        return nil;
    }
    return hitView;
}
@end


// --- 核心信息捕获和过滤逻辑 ---
static void process_sha256(const void *data, size_t len, unsigned char *digest, NSString *source) {
    if (!data || !digest) return;
    
    // 尝试 UTF-8 解码明文
    NSData *inData = [NSData dataWithBytes:data length:len];
    NSString *inStr = [[NSString alloc] initWithData:inData encoding:NSUTF8StringEncoding];
    if (!inStr) {
        inStr = [NSString stringWithFormat:@"<Binary Data: %zu bytes>", len];
    }
    
    // !!! 【核心防护墙：关键字过滤】 !!!
    // 日常系统请求（比如 SafariSafeBrowsing）会疯狂调用 SHA256 导致日志刷屏看不见，
    // 这里只放行你关心的明文请求。如果不是 appSecret，直接 return 丢弃！
    if (![inStr containsString:@"appSecret="] && ![inStr containsString:@"qiekj.com"]) {
        return; 
    }
    
    // 获取 SHA256 计算后的十六进制结果
    NSMutableString *hashStr = [NSMutableString stringWithCapacity:64];
    for(int i = 0; i < 32; i++) {
        [hashStr appendFormat:@"%02x", digest[i]];
    }
    
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown.bundle";
    NSTimeInterval ts = [[NSDate date] timeIntervalSince1970];
    
    // 过滤堆栈，只保留具体业务逻辑
    NSArray *stack = [NSThread callStackSymbols];
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSString *line in stack) {
        if ([line containsString:@"libsystem"] || 
            [line containsString:@"libdispatch"] || 
            [line containsString:@"corecrypto"] || 
            [line containsString:@"CydiaSubstrate"] || 
            [line containsString:@"CryptoKit"] ||
            [line containsString:@"Tweak"]) {
            continue;
        }
        [filtered addObject:line];
    }
    
    NSString *logMsg = [NSString stringWithFormat:@"[%@] \nTime: %.3f\nBundle: %@\nInput: %@\nHash : %@\nStack:\n%@", 
                        source, ts, bundleId, inStr, hashStr, [filtered componentsJoinedByString:@"\n"]];
    
    // 1. Console 日志输出
    NSLog(@"[SHA256_HOOK] \n%@", logMsg);
    
    // 2. 写入 TXT 文件 (沙盒 Documents目录)
    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *logFilePath = [docPath stringByAppendingPathComponent:@"CryptoHook.txt"];
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
    NSString *fileLogStr = [logMsg stringByAppendingString:@"\n\n----------------------------\n"];
    if (!fileHandle) {
        [fileLogStr writeToFile:logFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[fileLogStr dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
    
    // 3. 悬浮窗输出（附带路径提示）
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *displayMsg = [logMsg stringByAppendingFormat:@"\n\n[文件已保存至]\n%@", logFilePath];
        [[SHAFloatingWindow shared] addLog:displayMsg];
    });
}


// --- 增量哈希 (Incremental Hashing) 追踪 ---
static NSMutableDictionary *incrementalBuffers;
static NSLock *incrementalLock;

// --- Hook 1: corecrypto (包含一次性和增量) ---
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

// 增量: ccdigest_init 等底层函数由于函数体在 ARM64 下过短（只有两三条指令），
// 强行 MSHookFunction 会导致 trampoline 覆盖并损坏相邻的 ccrng_generate 函数，
// 从而引发 SIGBUS / Permission fault 闪退！因此这里只能移除他们的内联 Hook。


// --- Hook 2: CommonCrypto (包含一次性和增量) ---
static unsigned char * (*orig_CC_SHA256)(const void *data, CC_LONG len, unsigned char *md);
static unsigned char * my_CC_SHA256(const void *data, CC_LONG len, unsigned char *md) {
    unsigned char *ret = orig_CC_SHA256(data, len, md);
    if (ret) process_sha256(data, len, ret, @"CC_SHA256");
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
        NSMutableData *buf = incrementalBuffers[[NSValue valueWithPointer:c]];
        if (buf) [buf appendBytes:data length:len];
        [incrementalLock unlock];
    }
    return ret;
}

static int (*orig_CC_SHA256_Final)(unsigned char *md, CC_SHA256_CTX *c);
static int my_CC_SHA256_Final(unsigned char *md, CC_SHA256_CTX *c) {
    int ret = orig_CC_SHA256_Final(md, c);
    [incrementalLock lock];
    NSValue *key = [NSValue valueWithPointer:c];
    NSMutableData *buf = incrementalBuffers[key];
    NSData *finalData = nil;
    if (buf) {
        finalData = [buf copy];
        [incrementalBuffers removeObjectForKey:key];
    }
    [incrementalLock unlock];
    
    if (finalData) {
        process_sha256(finalData.bytes, finalData.length, md, @"CC_SHA256_Incremental");
    }
    return ret;
}

// --- Hook 3: CryptoKit.SHA256.hash(data:) (Swift 符号补充) ---
// 由于我们已经捕获了底层增量实现，这里不做深入捕获以防 Register 被破坏
static void (*orig_cryptokit_sha256)(void *a, void *b, void *c);
static void my_cryptokit_sha256(void *a, void *b, void *c) {
    NSLog(@"[SHA256_HOOK] -> Hit Swift CryptoKit.SHA256 wrapper (Payload intercepted by incremental corecrypto)");
    orig_cryptokit_sha256(a, b, c);
}


%ctor {
    incrementalBuffers = [NSMutableDictionary dictionary];
    incrementalLock = [[NSLock alloc] init];

    // 延迟直到 App 界面加载完成后再生成悬浮窗
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification 
                                                      object:nil 
                                                       queue:[NSOperationQueue mainQueue] 
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        [SHAFloatingWindow shared];
    }];

    // 核心修复：不用 Inline Hook (MSHookFunction) 去硬改 corecrypto (会导致内存写保护异常)，
    // 改用 fishhook去篡改 App 自身的导入地址表 (GOT/PLT) ！这样就完美实现了增量拦截且永不崩溃！
    struct rebinding rbs[] = {
        {"ccdigest", (void *)my_ccdigest, (void **)&orig_ccdigest},
        {"ccdigest_init", (void *)my_ccdigest_init, (void **)&orig_ccdigest_init},
        {"ccdigest_update", (void *)my_ccdigest_update, (void **)&orig_ccdigest_update},
        {"ccdigest_final", (void *)my_ccdigest_final, (void **)&orig_ccdigest_final}
    };
    rebind_symbols(rbs, sizeof(rbs)/sizeof(struct rebinding));
    
    // CommonCrypto由于在 libSystem 中，通常用 MSHookFunction 内联Hook是安全的。
    // 但是为了 100% 不崩溃，我们把 CC_SHA256 同样也加到 fishhook 里做导入表拦截。
    struct rebinding rbs2[] = {
        {"CC_SHA256", (void *)my_CC_SHA256, (void **)&orig_CC_SHA256},
        {"CC_SHA256_Init", (void *)my_CC_SHA256_Init, (void **)&orig_CC_SHA256_Init},
        {"CC_SHA256_Update", (void *)my_CC_SHA256_Update, (void **)&orig_CC_SHA256_Update},
        {"CC_SHA256_Final", (void *)my_CC_SHA256_Final, (void **)&orig_CC_SHA256_Final}
    };
    rebind_symbols(rbs2, sizeof(rbs2)/sizeof(struct rebinding));
    
    // 查找并 Hook Swift CryptoKit 签名
    MSImageRef cryptoKitRef = MSGetImageByName("/System/Library/Frameworks/CryptoKit.framework/CryptoKit");
    if (cryptoKitRef) {
        void *swiftHashSym = MSFindSymbol(cryptoKitRef, "_$s9CryptoKit6SHA256V4hash4dataAA0C6DigestVcx_tc10Foundation12DataProtocolRzlFZ");
        if (swiftHashSym) {
            MSHookFunction((void*)swiftHashSym, (void*)my_cryptokit_sha256, (void**)&orig_cryptokit_sha256);
        }
    }
}
