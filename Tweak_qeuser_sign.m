// Tweak_qeuser_sign.m
// ---------------------------------------------------------------------------
// 针对 胖乖生活 / QEUser (com.qiekj.QEUser) 的 sign 明文捕获补丁
//
// 为什么需要这个补丁 (静态分析结论):
//   1. QEUser 的 sign = SHA256("appSecret=<SEC>&channel=..&timestamp=..&token=..&version=..&<path>")
//   2. 二进制 __cstring 里有格式串
//        appSecret=%@&channel=%@&timestamp=%@&token=%@&version=%@&%@      @0x43ae7e0
//        appSecret=%@&categoryCode=%@&channel=%@&imei=%@&lat=%@&lng=%@&timestamp=%@&token=%@&version=%@&%@  @0x43934c0
//      → 明文是用 NSString format 家族拼的 (Swift String(format:) 也走这里)
//   3. QEUser 导入的 CryptoKit 符号是「流式」三件套 (protocol witness thunk):
//        _$s9CryptoKit12HashFunctionPxycfCTj                         init()
//        _$s9CryptoKit12HashFunctionP6update13bufferPointerySW_tFTj  update(bufferPointer:)
//        _$s9CryptoKit12HashFunctionP8finalize6DigestQzyFTj          finalize()
//      它 **没有** 导入一次性泛型符号 _$s9CryptoKit6SHA256V4hash4data...FZ,
//      所以原版 Tweak.x 里 MSHookFunction(CryptoKit.SHA256.hash(data:)) 对本 App 永不触发,
//      面板会显示 CryptoKitWrapper: hooked 却一条明文都收不到 ("Blind Trace" 就是这个意思)。
//
// 本文件的抓法 (与哈希走 CryptoKit 还是 CommonCrypto 无关):
//   A. hook NSString 的 format 家族, 先让原实现产出字符串, 再看结果里有没有 "appSecret=" → 直接拿到签名原文
//   B. hook CryptoKit 流式 update 的 witness thunk, 用 vm_region 安全探测参数布局 → 交叉验证
//   命中后本地再算一次 SHA256, 打印出来 == 请求头里的 sign, 一眼确认。
//
// ⚠️ 关于 B (CryptoKit.update) 的风险 (2026-10-04 发现):
//   CryptoKit.HashFunction.update 是**系统框架**的热点符号, 被 App/SDK 大量调用。
//   我们的 thunk 里做了 ObjC 操作 (QEReport → stringWithFormat/NSLog/description),
//   会在这条系统路径内部插入对象构造 => 破坏 CFString 的 in-mutation 状态
//   => 下游 description/appendFormat: 撞 mutateError => abort。
//   Hook 由 QE_HOOK_CRYPTOKIT_UPDATE 开关控制, 默认关闭;
//   只有当 A 路线 (stringWithFormat:) 抓不到明文时, 才打开它并接受该风险。
//
// 集成 (Makefile):
//   CryptoKitSHA256Hook_FILES = Tweak_qeuser_sign.m fishhook.c
// 日志与原版共用 Documents/CryptoHook.txt, 悬浮窗的 Copy 按钮一把复制。
// ---------------------------------------------------------------------------

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <substrate.h>

// CryptoKit.update 的 hook 会拦下**系统框架**的热点符号, 而我们的 thunk 里
// 会做 ObjC 操作 (QEReport) → 在系统哈希路径里插入对象构造 →
// 破坏 CFString 的 in-mutation 状态 → 下游 appendFormat: 撞 mutateError。
// 默认关闭; 若 A 路线 (stringWithFormat:) 抓不到明文, 再置 1 打开并接受风险。
#ifndef QE_HOOK_CRYPTOKIT_UPDATE
#define QE_HOOK_CRYPTOKIT_UPDATE 0
#endif

// 只记录含这些标记的字符串, 避免被广告 SDK 的噪声淹没; 清空 = 全记
static NSArray<NSString *> *QEMarks(void) { return @[@"appSecret=", @"_appid=", @"&timestamp="]; }

// 递归护栏: 我们自己打日志时也会 stringWithFormat, 不挡住会无限递归
static __thread int gQEInHook = 0;

static BOOL QEShouldLog(NSString *s) {
    if (gQEInHook) return NO;
    if (![s isKindOfClass:[NSString class]]) return NO;
    NSUInteger n = s.length;
    if (n == 0 || n > 8192) return NO;
    for (NSString *m in QEMarks()) if ([s rangeOfString:m].location != NSNotFound) return YES;
    return NO;
}

static NSString *QEHex(const void *p, NSUInteger n) {
    const unsigned char *b = p;
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static NSString *QESha256Of(NSString *plain) {
    NSData *d = [plain dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(d.bytes, (CC_LONG)d.length, md);
    return QEHex(md, sizeof(md));
}

static void QELog(NSString *tag, NSString *where, NSString *plain) {
    gQEInHook = 1;
    @try {
        NSString *msg = [NSString stringWithFormat:
            @"[%@]\nTime: %.3f\nWhere: %@\nPlaintext: %@\nLength: %lu\nSHA256(local): %@\n"
            @"Note: 上面的 SHA256 就是请求头 sign; 原文即 appSecret=... 拼接串\nStack:\n%@\n\n----------------------------\n",
            tag, [[NSDate date] timeIntervalSince1970], where, plain,
            (unsigned long)[plain lengthOfBytesUsingEncoding:NSUTF8StringEncoding], QESha256Of(plain),
            [[NSThread callStackSymbols] componentsJoinedByString:@"\n"]];
        NSLog(@"[QE_SIGN_HOOK] %@", msg);
        NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *path = [dir stringByAppendingPathComponent:@"CryptoHook.txt"];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[msg dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    } @catch (__unused NSException *e) {}
    gQEInHook = 0;
}

static void QEReport(NSString *tag, NSString *where, NSString *s) {
    if (QEShouldLog(s)) QELog(tag, where, s);
}

#pragma mark - A. NSString format 家族

// 变参方法不能直接把 orig IMP 当 C 函数转发 (会丢 va_list)。
// 做法: 类方法用 initWithFormat:arguments: 等价重建; 带 va_list 的原方法则原样转发。
//
// ★ 必须用 [[self alloc] ...] 而不是 [[NSString alloc] ...]:
//   +stringWithFormat: 是类方法, self 是**接收消息的类**, 不一定是 NSString.
//   例如 [NSMutableString stringWithFormat:@"..."] → self = NSMutableString,
//   原实现返回**可变**字符串; 若写死 NSString 就会降级成不可变 __NSCFString,
//   调用方随后 appendFormat: 撞 mutateError → 未捕获异常 → abort
//   (2026-10-04 三次崩溃 133051/181016/182534 的根因).

static NSString *new_stringWithFormat(id self, SEL _cmd, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    gQEInHook = 1;              // 走 hooked 的 initWithFormat:arguments: 时别重复记
    NSString *r = [[self alloc] initWithFormat:fmt arguments:ap];
    gQEInHook = 0;
    va_end(ap);
    QEReport(@"QE-SIGN-PLAINTEXT", @"+[NSString stringWithFormat:]", r);
    return r;
}

static NSString *new_localizedStringWithFormat(id self, SEL _cmd, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    gQEInHook = 1;
    NSString *r = [[self alloc] initWithFormat:fmt locale:[NSLocale currentLocale] arguments:ap];
    gQEInHook = 0;
    va_end(ap);
    QEReport(@"QE-SIGN-PLAINTEXT", @"+[NSString localizedStringWithFormat:]", r);
    return r;
}

static IMP gOrigInitFmtArgs = NULL;
static IMP gOrigInitFmtLocArgs = NULL;

static id new_initWithFormat_args(id self, SEL _cmd, NSString *fmt, va_list ap) {
    if (!gOrigInitFmtArgs) return nil;
    id r = ((id(*)(id, SEL, NSString *, va_list))gOrigInitFmtArgs)(self, _cmd, fmt, ap);
    QEReport(@"QE-SIGN-PLAINTEXT", @"-[NSString initWithFormat:arguments:]", r);
    return r;
}

static id new_initWithFormat_locale_args(id self, SEL _cmd, NSString *fmt, id locale, va_list ap) {
    if (!gOrigInitFmtLocArgs) return nil;
    id r = ((id(*)(id, SEL, NSString *, id, va_list))gOrigInitFmtLocArgs)(self, _cmd, fmt, locale, ap);
    QEReport(@"QE-SIGN-PLAINTEXT", @"-[NSString initWithFormat:locale:arguments:]", r);
    return r;
}

// 只读观察, 绝不改写返回值:
// 崩溃 104421 (mutateError) 就是改写返回值/可变性造成的。
// 而且对 receiver 调两次 stringByAppendingString: 会产生额外对象,
// 干扰 UIKit 的 description 路径 (见 133051)。
//
// ★ 这里必须用 [[self alloc] initWithFormat:arguments:] 而不是 [[NSString alloc] ...]:
//   stringByAppendingFormat: 的 receiver 可能是 NSMutableString 的子类实例,
//   重建 tail 时同样不能写死 NSString (否则 %@ 里嵌套的可变串又被降级).
static IMP gOrigAppendingFormat = NULL;

static NSString *new_appendingFormat(id self, SEL _cmd, NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    gQEInHook = 1;
    NSString *tail = [[NSString alloc] initWithFormat:fmt arguments:ap];
    gQEInHook = 0;
    va_end(ap);
    // ★ 原样调用原实现 (它内部走 NSString 的 stringByAppendingString:),
    //   拿到真正的返回值后再只看不碰
    NSString *r = gOrigAppendingFormat
        ? ((NSString *(*)(id, SEL, NSString *))gOrigAppendingFormat)(self, _cmd, tail)
        : nil;
    QEReport(@"QE-SIGN-PLAINTEXT", @"-[NSString stringByAppendingFormat:]", r);
    return r;
}

#pragma mark - B. CryptoKit 流式 witness thunk

// 用 vm_region 判断可读性, 猜错 ABI 也不会 SIGSEGV
#if QE_HOOK_CRYPTOKIT_UPDATE
static BOOL QESafeReadable(const void *ptr, size_t len) {
    if (!ptr || len == 0 || len > (1u << 22)) return NO;
    vm_address_t addr = (vm_address_t)ptr;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t obj = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64,
                     (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) return NO;
    if (!(info.protection & VM_PROT_READ)) return NO;
    return ((vm_address_t)ptr + len) <= (addr + size);
}

// 两种最可能的布局都试: (ptr,len,...) 或 (UnsafeBufferPointer box{ptr,len},...)
static NSString *QETryExtract(const void *a, const void *b) {
    if (!QESafeReadable(a, 16)) return nil;
    size_t len = (size_t)b;
    if (len > 0 && len < (1u << 20) && QESafeReadable(a, len)) {
        NSString *s = [[NSString alloc] initWithBytes:a length:len encoding:NSUTF8StringEncoding];
        if (s.length) return s;
    }
    const void *p2 = ((const void **)a)[0];
    size_t l2 = ((const size_t *)a)[1];
    if (l2 > 0 && l2 < (1u << 20) && QESafeReadable(p2, l2)) {
        NSString *s = [[NSString alloc] initWithBytes:p2 length:l2 encoding:NSUTF8StringEncoding];
        if (s.length) return s;
    }
    return nil;
}

static void (*orig_ck_update)(void *, void *, void *, void *);
static void my_ck_update(void *a, void *b, void *c, void *d) {
    NSString *s = QETryExtract(a, b) ?: QETryExtract(b, c);
    if (s) QEReport(@"QE-CRYPTOKIT-UPDATE", @"CryptoKit.HashFunction.update(bufferPointer:)", s);
    if (orig_ck_update) orig_ck_update(a, b, c, d);
}
#endif  // QE_HOOK_CRYPTOKIT_UPDATE

#pragma mark - 安装

static void QESwizzleClassMethod(const char *clsName, SEL sel, IMP newImp) {
    Method m = class_getClassMethod(objc_lookUpClass(clsName), sel);
    if (m) method_setImplementation(m, newImp);
}
static void QESwizzleInstanceMethod(const char *clsName, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(objc_lookUpClass(clsName), sel);
    if (!m) return;
    if (outOrig) *outOrig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

__attribute__((constructor)) static void QESignHookCtor(void) {
    // 与原版 Tweak.x 一致: 延迟到主线程安装, 避开 dyld 初始化期改 __DATA_CONST 触发 SIGBUS
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        QESwizzleClassMethod("NSString", @selector(stringWithFormat:), (IMP)new_stringWithFormat);
        QESwizzleClassMethod("NSString", @selector(localizedStringWithFormat:), (IMP)new_localizedStringWithFormat);

        Method m1 = class_getInstanceMethod([NSString class], @selector(initWithFormat:arguments:));
        if (m1) { gOrigInitFmtArgs = method_getImplementation(m1); method_setImplementation(m1, (IMP)new_initWithFormat_args); }
        Method m2 = class_getInstanceMethod([NSString class], @selector(initWithFormat:locale:arguments:));
        if (m2) { gOrigInitFmtLocArgs = method_getImplementation(m2); method_setImplementation(m2, (IMP)new_initWithFormat_locale_args); }
        // 不 hook -[NSMutableString appendFormat:]: in-place 修改 self, 风险高,
        // 而 stringWithFormat: 层已能覆盖签名明文
        QESwizzleInstanceMethod("NSString", @selector(stringByAppendingFormat:), (IMP)new_appendingFormat, &gOrigAppendingFormat);

        // CryptoKit 流式 update 的 witness thunk —— 见文件头 ⚠️ 说明, 默认关闭
        BOOL ckHooked = NO;
        void *p = NULL;
#if QE_HOOK_CRYPTOKIT_UPDATE
        const char *ckPath = "/System/Library/Frameworks/CryptoKit.framework/CryptoKit";
        void *ck = dlopen(ckPath, RTLD_LAZY);
        MSImageRef img = ck ? MSGetImageByName(ckPath) : NULL;
        const char *sym = "_$s9CryptoKit12HashFunctionP6update13bufferPointerySW_tFTj";
        p = img ? MSFindSymbol(img, sym) : (ck ? dlsym(ck, sym) : NULL);
        if (p) { MSHookFunction(p, (void *)my_ck_update, (void **)&orig_ck_update); ckHooked = YES; }
#endif

        gQEInHook = 1;
        // ★ 必须用 @"..." 字面量直传, 不能用 [NSString stringWithFormat:] 先拼
        //   —— 那会重入我们刚装的 format hook
        NSLog(@"[QE_SIGN_HOOK] installed: stringWithFormat=ok initWithFormat:arguments:=%p "
              @"initWithFormat:locale:arguments:=%p CryptoKit.update=%@(%p) filter=%@",
              gOrigInitFmtArgs, gOrigInitFmtLocArgs,
              ckHooked ? @"hooked" : @"symbol-not-found", p, [QEMarks() componentsJoinedByString:@","]);
        gQEInHook = 0;
    });
}
