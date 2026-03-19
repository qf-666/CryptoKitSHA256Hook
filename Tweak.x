#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>
#import <CommonCrypto/CommonCrypto.h>

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
        win.userInteractionEnabled = NO; // 不阻挡底层点击
        win.hidden = NO;
        win.backgroundColor = [UIColor clearColor];

        // 顶部悬浮框
        UITextView *tv = [[UITextView alloc] initWithFrame:CGRectMake(10, 80, [UIScreen mainScreen].bounds.size.width - 20, 250)];
        tv.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        tv.textColor = [UIColor systemGreenColor];
        tv.font = [UIFont systemFontOfSize:10];
        tv.editable = NO;
        tv.layer.cornerRadius = 8;
        tv.clipsToBounds = YES;
        [win addSubview:tv];
        win.textView = tv;
    });
    return win;
}
- (void)addLog:(NSString *)log {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.textView) return;
        self.textView.text = [NSString stringWithFormat:@"%@\n\n%@", log, self.textView.text];
    });
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
    
    // 2. 悬浮窗输出
    dispatch_async(dispatch_get_main_queue(), ^{
        [[SHAFloatingWindow shared] addLog:logMsg];
    });
}


// --- Hook 1: ccdigest (corecrypto 底层兜底) ---
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
    if (di && di->output_size == 32) { // 32 bytes = 256 bits
        process_sha256(data, len, (unsigned char *)digest, @"ccdigest");
    }
}


// --- Hook 2: CC_SHA256 (CommonCrypto 补充兜底) ---
static unsigned char * (*orig_CC_SHA256)(const void *data, CC_LONG len, unsigned char *md);
static unsigned char * my_CC_SHA256(const void *data, CC_LONG len, unsigned char *md) {
    unsigned char *ret = orig_CC_SHA256(data, len, md);
    if (ret) {
        process_sha256(data, len, ret, @"CC_SHA256");
    }
    return ret;
}


// --- Hook 3: CryptoKit.SHA256.hash(data:) (Swift 符号补充) ---
// 注意：Swift 泛型签名会附带 witness table, 为了不破坏寄存器，这里只监听拦截但不读取其 payload
// (由于 CryptoKit 在 iOS 上固定依赖 ccdigest，明文和 cipher 都会落在 Hook 1 中安全解析)
static void (*orig_cryptokit_sha256)(void *a, void *b, void *c);
static void my_cryptokit_sha256(void *a, void *b, void *c) {
    NSLog(@"[SHA256_HOOK] -> Hit Swift CryptoKit.SHA256 wrapper (Payload intercepted by ccdigest)");
    orig_cryptokit_sha256(a, b, c);
}


%ctor {
    // 延迟直到 App 界面加载完成后再生成悬浮窗
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification 
                                                      object:nil 
                                                       queue:[NSOperationQueue mainQueue] 
                                                  usingBlock:^(NSNotification * _Nonnull note) {
        [SHAFloatingWindow shared];
    }];

    // 动态查找并 Hook ccdigest
    void *corecrypto = dlopen("/usr/lib/system/libcorecrypto.dylib", RTLD_NOW);
    if (corecrypto) {
        void *sym = dlsym(corecrypto, "ccdigest");
        if (sym) {
            MSHookFunction((void *)sym, (void *)my_ccdigest, (void **)&orig_ccdigest);
        }
    }
    
    // Hook CC_SHA256
    MSHookFunction((void *)CC_SHA256, (void *)my_CC_SHA256, (void **)&orig_CC_SHA256);
    
    // 查找并 Hook Swift CryptoKit 签名
    MSImageRef cryptoKitRef = MSGetImageByName("/System/Library/Frameworks/CryptoKit.framework/CryptoKit");
    if (cryptoKitRef) {
        void *swiftHashSym = MSFindSymbol(cryptoKitRef, "_$s9CryptoKit6SHA256V4hash4dataAA0C6DigestVcx_tc10Foundation12DataProtocolRzlFZ");
        if (swiftHashSym) {
            MSHookFunction((void*)swiftHashSym, (void*)my_cryptokit_sha256, (void**)&orig_cryptokit_sha256);
        }
    }
}
