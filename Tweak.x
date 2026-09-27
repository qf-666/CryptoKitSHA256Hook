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



static long long gRawHookHitCount = 0;
static long long gUTF8HitCount = 0;

static NSMutableDictionary *incrementalBuffers;
static NSLock *incrementalLock;
static unsigned char *(*orig_CC_SHA256)(const void *data, CC_LONG len, unsigned char *md);
static BOOL gDidInstallCryptoKitWrapper = NO;

static NSString *const kThreadSourceHintKey = @"CryptoKitSHA256Hook.SourceHint";
static NSString *const kThreadUTF8CandidateTextKey = @"CryptoKitSHA256Hook.UTF8CandidateText";
static NSString *const kThreadUTF8CandidateSourceKey = @"CryptoKitSHA256Hook.UTF8CandidateSource";
static NSString *const kThreadUTF8CandidateBytesKey = @"CryptoKitSHA256Hook.UTF8CandidateBytes";
static NSString *const kThreadUTF8CandidateLoggedKey = @"CryptoKitSHA256Hook.UTF8CandidateLogged";
static NSString *const kThreadBridgeSuppressionDepthKey = @"CryptoKitSHA256Hook.BridgeSuppressionDepth";

static NSString *utf8StringFromBytes(const void *bytes, size_t length) {
    if (!bytes || length == 0) {
        return @"";
    }

    NSString *utf8 = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    return utf8.length > 0 ? utf8 : nil;
}

static NSString *hexPreviewFromBytes(const void *bytes, size_t length, NSUInteger maxBytes) {
    if (!bytes || length == 0) {
        return @"<empty>";
    }

    NSUInteger previewLength = MIN((NSUInteger)length, maxBytes);
    const unsigned char *raw = (const unsigned char *)bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:(previewLength * 2) + 16];
    for (NSUInteger i = 0; i < previewLength; i++) {
        [hex appendFormat:@"%02x", raw[i]];
    }
    if ((NSUInteger)length > previewLength) {
        [hex appendString:@"..."];
    }
    return hex;
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

static NSString *sha256HexForData(NSData *data) {
    if (data.length == 0) {
        return @"<empty-input>";
    }

    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    if (orig_CC_SHA256) {
        orig_CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    } else {
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    }
    return digestHexString(digest, CC_SHA256_DIGEST_LENGTH);
}

static BOOL isLikelyDisplayableUTF8(NSString *text) {
    if (text.length == 0 || text.length > 4096) {
        return NO;
    }
    if ([text hasPrefix:@"[SHA256"] ||
        [text hasPrefix:@"[Generic SHA256 Hook]"] ||
        [text hasPrefix:@"[Saved]"]) {
        return NO;
    }

    NSUInteger suspiciousCount = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar ch = [text characterAtIndex:i];
        BOOL allowedControl = (ch == '\n' || ch == '\r' || ch == '\t');
        if (ch < 0x20 && !allowedControl) {
            suspiciousCount++;
        }
    }
    return suspiciousCount == 0;
}

static NSInteger currentThreadCounter(NSString *key) {
    return [[[[NSThread currentThread] threadDictionary] objectForKey:key] integerValue];
}

static BOOL isBridgeSuppressed(void) {
    return currentThreadCounter(kThreadBridgeSuppressionDepthKey) > 0;
}

static void pushBridgeSuppression(void) {
    NSMutableDictionary *threadInfo = [[NSThread currentThread] threadDictionary];
    NSInteger depth = [threadInfo[kThreadBridgeSuppressionDepthKey] integerValue];
    threadInfo[kThreadBridgeSuppressionDepthKey] = @(depth + 1);
}

static void popBridgeSuppression(void) {
    NSMutableDictionary *threadInfo = [[NSThread currentThread] threadDictionary];
    NSInteger depth = [threadInfo[kThreadBridgeSuppressionDepthKey] integerValue];
    if (depth <= 1) {
        [threadInfo removeObjectForKey:kThreadBridgeSuppressionDepthKey];
        return;
    }
    threadInfo[kThreadBridgeSuppressionDepthKey] = @(depth - 1);
}

static void rememberThreadUTF8Candidate(NSString *text, NSData *bytes, NSString *source) {
    if (isBridgeSuppressed() || !isLikelyDisplayableUTF8(text) || bytes.length == 0) {
        return;
    }

    NSMutableDictionary *threadInfo = [[NSThread currentThread] threadDictionary];
    threadInfo[kThreadUTF8CandidateTextKey] = [text copy];
    threadInfo[kThreadUTF8CandidateSourceKey] = source ?: @"unknown";
    threadInfo[kThreadUTF8CandidateBytesKey] = [bytes copy];
    [threadInfo removeObjectForKey:kThreadUTF8CandidateLoggedKey];
}

static void rememberThreadUTF8CandidateFromBytes(const void *bytes, size_t length, NSString *source) {
    if (isBridgeSuppressed()) {
        return;
    }

    NSString *text = utf8StringFromBytes(bytes, length);
    if (text.length == 0) {
        return;
    }

    NSData *data = [[NSData alloc] initWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
    rememberThreadUTF8Candidate(text, data, source);
}

static NSDictionary<NSString *, id> *currentThreadUTF8Candidate(void) {
    NSMutableDictionary *threadInfo = [[NSThread currentThread] threadDictionary];
    NSString *text = threadInfo[kThreadUTF8CandidateTextKey];
    NSData *bytes = threadInfo[kThreadUTF8CandidateBytesKey];
    if (text.length == 0 || bytes.length == 0) {
        return nil;
    }

    return @{
        @"text": text,
        @"bytes": bytes,
        @"source": threadInfo[kThreadUTF8CandidateSourceKey] ?: @"unknown",
        @"logged": threadInfo[kThreadUTF8CandidateLoggedKey] ?: @NO
    };
}

static void markThreadUTF8CandidateLogged(void) {
    NSMutableDictionary *threadInfo = [[NSThread currentThread] threadDictionary];
    threadInfo[kThreadUTF8CandidateLoggedKey] = @YES;
}

static NSDictionary<NSString *, id> *pendingThreadUTF8Candidate(void) {
    if (isBridgeSuppressed()) {
        return nil;
    }

    NSDictionary<NSString *, id> *candidate = currentThreadUTF8Candidate();
    if ([candidate[@"logged"] boolValue] || !candidate[@"text"]) {
        return nil;
    }
    return candidate;
}

static NSString *setThreadSourceHint(NSString *hint) {
    NSMutableDictionary *threadInfo = [[NSThread currentThread] threadDictionary];
    NSString *previousHint = threadInfo[kThreadSourceHintKey];
    if (hint.length > 0) {
        threadInfo[kThreadSourceHintKey] = hint;
    } else {
        [threadInfo removeObjectForKey:kThreadSourceHintKey];
    }
    return previousHint;
}

static void restoreThreadSourceHint(NSString *previousHint) {
    NSMutableDictionary *threadInfo = [[NSThread currentThread] threadDictionary];
    if (previousHint.length > 0) {
        threadInfo[kThreadSourceHintKey] = previousHint;
    } else {
        [threadInfo removeObjectForKey:kThreadSourceHintKey];
    }
}

static NSString *resolvedSourceName(NSString *source) {
    NSString *hint = [[[NSThread currentThread] threadDictionary] objectForKey:kThreadSourceHintKey];
    if (hint.length == 0) {
        return source ?: @"unknown";
    }
    if (source.length == 0 || [hint isEqualToString:source]) {
        return hint;
    }
    return [NSString stringWithFormat:@"%@ -> %@", hint, source];
}

static NSString *filteredStackTrace(void) {
    pushBridgeSuppression();
    NSString *result = @"<stack-filtered>";
    @try {
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

        if (filteredStack.count > 0) {
            result = [filteredStack componentsJoinedByString:@"\n"];
        }
    } @finally {
        popBridgeSuppression();
    }
    return result;
}

static void appendLogMessage(NSString *logMessage, NSString *source, NSString *note, long long rawHits);

static void appendUTF8CandidateLog(NSDictionary<NSString *, id> *candidate, NSString *source, NSString *meaning, NSString *note) {
    NSString *text = candidate[@"text"];
    NSData *bytes = candidate[@"bytes"];
    if (text.length == 0 || bytes.length == 0) {
        return;
    }

    long long rawHits = __sync_add_and_fetch(&gRawHookHitCount, 1);
    __sync_add_and_fetch(&gUTF8HitCount, 1);
    NSString *resolvedSource = resolvedSourceName(source);
    NSString *candidateSource = candidate[@"source"] ?: @"unknown";
    NSString *logMessage = [NSString stringWithFormat:
                            @"[SHA256 UTF8 Bridge #%lld]\n"
                            @"Source: %@\n"
                            @"BridgeSource: %@\n"
                            @"Algorithm: SHA-256\n"
                            @"Meaning: %@\n"
                            @"InputLength: %lu\n"
                            @"InputType: UTF-8 text\n"
                            @"Plaintext: %@\n"
                            @"HexPreview: %@\n"
                            @"Hash(Local): %@\n"
                            @"Stack:\n%@",
                            rawHits,
                            resolvedSource,
                            candidateSource,
                            meaning ?: @"runtime UTF-8 candidate before SHA256",
                            (unsigned long)bytes.length,
                            text,
                            hexPreviewFromBytes(bytes.bytes, bytes.length, 96),
                            sha256HexForData(bytes),
                            filteredStackTrace()];
    appendLogMessage(logMessage, resolvedSource, note ?: @"utf8-bridge", rawHits);
    markThreadUTF8CandidateLogged();
}

static void appendLogMessage(NSString *logMessage, NSString *source, NSString *note, long long rawHits) {
    pushBridgeSuppression();

    NSString *logFilePath = nil;
    @try {
        NSString *documentsPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        logFilePath = [documentsPath stringByAppendingPathComponent:@"CryptoHook.txt"];
        NSString *fileLogString = [logMessage stringByAppendingString:@"\n\n----------------------------\n"];
        NSData *logFileData = [fileLogString dataUsingEncoding:NSUTF8StringEncoding];

        if (logFileData.length > 0) {
            NSFileManager *fileManager = [NSFileManager defaultManager];
            if (![fileManager fileExistsAtPath:logFilePath]) {
                [fileManager createFileAtPath:logFilePath contents:nil attributes:nil];
            }

            NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
            if (fileHandle) {
                [fileHandle seekToEndOfFile];
                [fileHandle writeData:logFileData];
                [fileHandle closeFile];
            }
        }
    } @finally {
        popBridgeSuppression();
    }
}

static void process_sha256(const void *data, size_t len, unsigned char *digest, NSString *source) {
    if (!data || !digest) {
        return;
    }

    long long rawHits = __sync_add_and_fetch(&gRawHookHitCount, 1);
    NSString *utf8String = utf8StringFromBytes(data, len);
    BOOL hasUTF8Text = (utf8String.length > 0);
    if (hasUTF8Text) {
        __sync_add_and_fetch(&gUTF8HitCount, 1);
        rememberThreadUTF8CandidateFromBytes(data, len, source ?: @"SHA256Input");
    }

    NSDictionary<NSString *, id> *bridgeCandidate = nil;
    if (!hasUTF8Text && !gDidInstallCryptoKitWrapper) {
        bridgeCandidate = pendingThreadUTF8Candidate();
    }
    BOOL debugBinarySample = (!hasUTF8Text && rawHits <= 8);
    BOOL passesDisplayFilter = hasUTF8Text || debugBinarySample || (bridgeCandidate != nil);
    NSString *resolvedSource = resolvedSourceName(source);

    if (!passesDisplayFilter) {
        return;
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown.bundle";
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSince1970];
    NSString *hexPreview = hexPreviewFromBytes(data, len, 96);
    NSString *logMessage = [NSString stringWithFormat:
                            @"[SHA256 #%lld]\n"
                            @"Source: %@\n"
                            @"Algorithm: SHA-256\n"
                            @"Meaning: runtime final SHA256 input\n"
                            @"Time: %.3f\n"
                            @"Bundle: %@\n"
                            @"InputLength: %zu\n"
                            @"InputType: %@\n"
                            @"Plaintext: %@\n"
                            @"HexPreview: %@\n"
                            @"Hash: %@\n"
                            @"Stack:\n%@",
                            rawHits,
                            resolvedSource,
                            timestamp,
                            bundleId,
                            len,
                            hasUTF8Text ? @"UTF-8 text" : @"binary-preview",
                            hasUTF8Text ? utf8String : @"<non-utf8>",
                            hexPreview,
                            digestHexString(digest, 32),
                            filteredStackTrace()];

    NSLog(@"[SHA256_HOOK]\n%@", logMessage);
    appendLogMessage(logMessage,
                     resolvedSource,
                     (hasUTF8Text ? @"utf8" : (bridgeCandidate ? @"utf8-bridge" : @"binary-sample")),
                     rawHits);
    if (hasUTF8Text) {
        markThreadUTF8CandidateLogged();
    } else if (bridgeCandidate) {
        appendUTF8CandidateLog(bridgeCandidate,
                               resolvedSource,
                               @"same-thread UTF-8 candidate correlated with SHA256 when direct plaintext was not observable",
                               @"utf8-bridge-correlated");
    }
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
    NSString *previousHint = setThreadSourceHint(@"CryptoKit.SHA256");
    @try {
        NSDictionary<NSString *, id> *candidate = pendingThreadUTF8Candidate();
        if (candidate) {
            appendUTF8CandidateLog(candidate,
                                   @"CryptoKit.SHA256",
                                   @"runtime UTF-8 candidate immediately before CryptoKit.SHA256",
                                   @"cryptokit-bridge");
        }
        orig_cryptokit_sha256(a, b, c);
    } @finally {
        restoreThreadSourceHint(previousHint);
    }
}

%hook NSString

- (NSData *)dataUsingEncoding:(NSStringEncoding)encoding {
    NSData *result = %orig;
    if (!isBridgeSuppressed() && encoding == NSUTF8StringEncoding && result.length > 0) {
        rememberThreadUTF8Candidate(self, result, @"NSString.dataUsingEncoding");
    }
    return result;
}

- (NSData *)dataUsingEncoding:(NSStringEncoding)encoding allowLossyConversion:(BOOL)lossyConversion {
    NSData *result = %orig;
    if (!isBridgeSuppressed() && encoding == NSUTF8StringEncoding && result.length > 0) {
        rememberThreadUTF8Candidate(self, result, @"NSString.dataUsingEncoding(lossy)");
    }
    return result;
}

%end

static void installHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
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
                gDidInstallCryptoKitWrapper = YES;
            }
        }

        long long rawHits = __sync_add_and_fetch(&gRawHookHitCount, 0);
        NSString *startupMessage = [NSString stringWithFormat:
                                    @"[Generic SHA256 Hook]\n"
                                    @"Status: installed\n"
                                    @"Meaning: capture runtime SHA256 input without business-specific symbols\n"
                                    @"OneShot: CC_SHA256\n"
                                    @"Incremental: CC_SHA256_Init/Update/Final + ccdigest_init/update/final\n"
                                    @"CryptoKitWrapper: %@\n"
                                    @"UTF8Bridge: deferred correlate on SHA hit\n"
                                    @"DisplayRule: show all UTF-8 inputs, sample first binary inputs",
                                    gDidInstallCryptoKitWrapper ? @"hooked" : @"symbol-not-found"];
        appendLogMessage(startupMessage,
                         @"Runtime",
                         @"installed",
                         rawHits);
    });
}

%ctor {
    incrementalBuffers = [NSMutableDictionary dictionary];
    incrementalLock = [[NSLock alloc] init];

    // rebind_symbols writes to __DATA_CONST (lazy/non-lazy pointer tables).
    // During dyld initializer execution that segment may already be demoted to
    // read-only, causing SIGBUS on launch. Defer all symbol patching to the
    // main thread after the app finished loading.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        installHooks();
    });
}
