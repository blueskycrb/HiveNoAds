//
// WCallRecorder - free rewrite for HiveNoAds (no license / no auth)
//
// Target:
//   WeChat 8.0.71 + iOS 14+/16.x + Bootstrap/RootHide
//
// Bootstrap / RootHide jailbreak tweak style (same as WeAppHelper):
//   Package: com.blueskycrb.wcallrecorder-rootless (iphoneos-arm64e)
//   Filter:  com.tencent.xin
//
// Pure Objective-C runtime hooks (no Substrate link dependency).
// Independent rewrite based on public symbol analysis of commercial
// WCallRecorder.dylib lifecycle selectors. No DRM / no network auth.
//
// 8.0.71 notes:
//   - VoIP/ilink/MultiTalk modules are often LAZY-LOADED on first call
//   - So we re-scan audio hooks when a call starts
//   - Prefer known 8.0.x class names when present, else selector scan
//
// Save path (WeChat sandbox):
//   Documents/WCallRecorder/<yyyyMMdd-HHmmss-hint>/{mic,remote,mixed}.wav + meta.json  (free v0.3.0)
//
// Defaults:
//   WCR.Enabled       (BOOL, default YES)
//   WCR.ShowIndicator (BOOL, default YES)
//   WCR.PrivateMode   (BOOL, default NO)
//   WCR.SampleRate    (double, default 16000)
//   WCR.WriteMixed    (BOOL, default YES)
//   WCR.Verbose       (BOOL, default NO)
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <math.h>
#import <stdatomic.h>
#import <ctype.h>

#pragma mark - Config

static BOOL WCRVerboseFlag(void);
#define WCRLog(fmt, ...) do { if (WCRVerboseFlag()) NSLog(@"[WCallRecorder] " fmt, ##__VA_ARGS__); } while (0)
#define WCRInfo(fmt, ...) NSLog(@"[WCallRecorder] " fmt, ##__VA_ARGS__)

static NSString * const kWCREnabledKey    = @"WCR.Enabled";
static NSString * const kWCRIndicatorKey  = @"WCR.ShowIndicator";
static NSString * const kWCRPrivateKey    = @"WCR.PrivateMode";
static NSString * const kWCRSampleRateKey = @"WCR.SampleRate";
static NSString * const kWCRWriteMixedKey = @"WCR.WriteMixed";
static NSString * const kWCRVerboseKey    = @"WCR.Verbose";
static NSString * const kWCRPluginVersion = @"0.3.0";

static void WCRShowToast(NSString *text);
static void WCRUpdateIndicator(BOOL on);

// Optional manual audio hooks after Frida recon for your WeChat build:
// @[@"ClassName", @"selector:name:", @"mic"|"remote"]
static NSArray<NSArray<NSString *> *> *WCRExtraAudioHooks(void) {
    static NSArray *hooks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        hooks = @[
            // @[@"VOIPAudioUnitService", @"onMicData:length:sampleRate:", @"mic"],
            // @[@"VOIPAudioUnitService", @"onPlayData:length:sampleRate:", @"remote"],
        ];
    });
    return hooks;
}

static NSUserDefaults *WCRDefaults(void) { return [NSUserDefaults standardUserDefaults]; }

static BOOL WCRBool(NSString *key, BOOL fallback) {
    NSUserDefaults *ud = WCRDefaults();
    if ([ud objectForKey:key] == nil) return fallback;
    return [ud boolForKey:key];
}

static double WCRPreferredSampleRate(void) {
    double v = [WCRDefaults() doubleForKey:kWCRSampleRateKey];
    if (v >= 8000.0 && v <= 48000.0) return v;
    return 16000.0;
}

static BOOL WCREnabled(void) { return WCRBool(kWCREnabledKey, YES); }
static BOOL WCRVerboseFlag(void) { return WCRBool(kWCRVerboseKey, NO); }
static BOOL WCRWriteMixed(void) { return WCRBool(kWCRWriteMixedKey, YES); }

// Portable case-insensitive substring (avoid relying on GNU strcasestr).
static BOOL WCRCaseContains(const char *hay, const char *needle) {
    if (!hay || !needle || !*needle) return NO;
    size_t nlen = strlen(needle);
    for (const char *p = hay; *p; p++) {
        size_t i = 0;
        while (i < nlen) {
            unsigned char a = (unsigned char)p[i];
            unsigned char b = (unsigned char)needle[i];
            if (!a) return NO;
            if (tolower(a) != tolower(b)) break;
            i++;
        }
        if (i == nlen) return YES;
    }
    return NO;
}


// WeChat 8.0.71-era class candidates (existence-checked at runtime).
static NSArray<NSString *> *WCRPreferredClasses(void) {
    static NSArray *arr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        arr = @[
            @"VOIPMgr", @"VoIPMgr", @"VOIPComponentMgr", @"VOIPHelper",
            @"VoIPUIManager", @"VOIPVideoRender", @"VOIPAudioUnitService",
            @"AUAudioDevice", @"AudioDevice", @"WCAudioModule", @"WCAudioSession",
            @"MultiTalkMgr", @"MultiTalkMainViewController", @"MultiTalkContact",
            @"IlinkService", @"MMIlinkService", @"IlinkVoIPMgr",
            @"IlinkMTService", @"CloudVoIPMgr", @"LiveVoIPViewController", @"VoIPViewController",
            @"VoIPPushKitExt", @"WCCallKitManager", @"VoIPInvitationService",
            @"WXTalkComponent", @"TalkEngineMgr", @"ConfDeviceManager",
            @"CContactMgr", @"MMServiceCenter", @"MMContext"
        ];
    });
    return arr;
}

static atomic_int gWCRAudioHooksInstalled = 0;

#pragma mark - Runtime helpers

static BOOL WCRClassHasOwnInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) { found = YES; break; }
    }
    if (methods) free(methods);
    return found;
}

static NSMutableSet *WCRHookedKeys(void) {
    static NSMutableSet *set;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ set = [NSMutableSet new]; });
    return set;
}

static NSMutableDictionary<NSString *, NSValue *> *WCROrigMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ map = [NSMutableDictionary new]; });
    return map;
}

static NSString *WCRHookKey(Class cls, SEL sel) {
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}

static void WCRStoreOrig(Class cls, SEL sel, IMP orig) {
    if (!cls || !sel || !orig) return;
    WCROrigMap()[WCRHookKey(cls, sel)] = [NSValue valueWithPointer:orig];
}

static IMP WCRLookupOrig(id self, SEL cmd) {
    if (!self || !cmd) return NULL;
    Class cls = object_getClass(self);
    while (cls) {
        NSValue *v = WCROrigMap()[WCRHookKey(cls, cmd)];
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}


static BOOL WCRHookInstance(Class cls, SEL sel, IMP newImp) {
    if (!cls || !sel || !newImp) return NO;
    NSString *key = WCRHookKey(cls, sel);
    if ([WCRHookedKeys() containsObject:key]) {
        return NO; // already hooked; avoid breaking orig chain on rescan
    }
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP cur = method_getImplementation(m);
    if (cur == newImp) {
        [WCRHookedKeys() addObject:key];
        return NO;
    }
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;
    WCRStoreOrig(cls, sel, cur);
    if (WCRClassHasOwnInstanceMethod(cls, sel)) {
        method_setImplementation(m, newImp);
    } else {
        if (!class_addMethod(cls, sel, newImp, types)) {
            method_setImplementation(class_getInstanceMethod(cls, sel), newImp);
        }
    }
    [WCRHookedKeys() addObject:key];
    WCRLog("hooked -[%s %s]", class_getName(cls), sel_getName(sel));
    return YES;
}

static Class WCRFindClassForSelector(SEL sel, BOOL preferVoipName) {
    if (!sel) return Nil;

    // 1) Prefer known 8.0.71-era classes first (fast + stable).
    for (NSString *name in WCRPreferredClasses()) {
        Class cls = NSClassFromString(name);
        if (cls && class_getInstanceMethod(cls, sel)) return cls;
    }

    // 2) Full scan fallback.
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    Class found = Nil;
    Class weakFound = Nil;
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        if (!class_getInstanceMethod(cls, sel)) continue;
        const char *name = class_getName(cls);
        if (!name) continue;
        if (preferVoipName &&
            (WCRCaseContains(name, "voip") || WCRCaseContains(name, "multitalk") ||
             WCRCaseContains(name, "ilink") || WCRCaseContains(name, "audio") ||
             WCRCaseContains(name, "conf") || WCRCaseContains(name, "talk") ||
             WCRCaseContains(name, "cloud") || WCRCaseContains(name, "live"))) {
            found = cls;
            break;
        }
        if (!weakFound) weakFound = cls;
    }
    free(classes);
    return found ?: weakFound;
}

static NSString *WCRSafeDesc(id obj) {
    if (!obj) return nil;
    @try {
        if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
        if ([obj respondsToSelector:@selector(stringValue)]) {
            id v = ((id(*)(id, SEL))objc_msgSend)(obj, @selector(stringValue));
            if ([v isKindOfClass:[NSString class]]) return v;
        }
        return [obj description];
    } @catch (__unused NSException *e) { return nil; }
}

static NSString *WCRSanitizeName(NSString *name) {
    if (name.length == 0) return @"unknown";
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_') {
            [out appendFormat:@"%C", c];
        } else if (c > 127) {
            [out appendFormat:@"u%04x", c];
        } else {
            [out appendString:@"_"];
        }
    }
    if (out.length == 0) return @"unknown";
    if (out.length > 48) return [out substringToIndex:48];
    return out;
}



static NSString *WCRPropString(id obj, NSArray<NSString *> *names) {
    if (!obj) return nil;
    for (NSString *name in names) {
        @try {
            SEL sel = NSSelectorFromString(name);
            if (![obj respondsToSelector:sel]) continue;
            id v = ((id(*)(id, SEL))objc_msgSend)(obj, sel);
            NSString *s = WCRSafeDesc(v);
            if (s.length > 0 && ![s isEqualToString:@"(null)"]) return s;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

static NSString *WCRContactHintFromObject(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        if (arr.count == 0) return @"multitalk";
        NSMutableArray *parts = [NSMutableArray array];
        NSUInteger limit = MIN(arr.count, (NSUInteger)3);
        for (NSUInteger i = 0; i < limit; i++) {
            NSString *p = WCRContactHintFromObject(arr[i]);
            if (p.length) [parts addObject:p];
        }
        if (parts.count) return [parts componentsJoinedByString:@"_"];
        return @"multitalk";
    }
    NSString *nick = WCRPropString(obj, @[
        @"m_nsNickName", @"m_nsRemark", @"m_nsUsrName", @"userName",
        @"displayName", @"nickname", @"nickName", @"m_nsFullName",
        @"mMultiTalkGroupId", @"groupChatroom", @"m_chatRoomName",
        @"m_roomContact", @"contact", @"remoteContact"
    ]);
    if (nick.length) return nick;
    for (NSString *key in @[@"m_contact", @"contact", @"m_roomContact", @"remoteContact", @"toContact", @"fromContact"]) {
        @try {
            SEL sel = NSSelectorFromString(key);
            if (![obj respondsToSelector:sel]) continue;
            id nested = ((id(*)(id, SEL))objc_msgSend)(obj, sel);
            NSString *s = WCRContactHintFromObject(nested);
            if (s.length) return s;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

#pragma mark - WAV writer (Foundation only)

@interface WCRWavWriter : NSObject
@property (nonatomic, copy) NSString *path;
@property (nonatomic, assign) double sampleRate;
@property (nonatomic, assign) uint16_t channels;
@property (nonatomic, strong) NSFileHandle *handle;
@property (nonatomic, assign) uint32_t dataBytes;
@property (nonatomic, assign) BOOL open;
@end

@implementation WCRWavWriter
- (instancetype)initWithPath:(NSString *)path sampleRate:(double)sr channels:(uint16_t)ch {
    self = [super init];
    if (self) {
        _path = [path copy];
        _sampleRate = sr > 0 ? sr : 16000.0;
        _channels = ch > 0 ? ch : 1;
    }
    return self;
}
- (BOOL)openFile {
    if (self.open) return YES;
    NSString *dir = [self.path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([[NSFileManager defaultManager] fileExistsAtPath:self.path]) {
        [[NSFileManager defaultManager] removeItemAtPath:self.path error:nil];
    }
    if (![[NSFileManager defaultManager] createFileAtPath:self.path contents:nil attributes:nil]) return NO;
    self.handle = [NSFileHandle fileHandleForWritingAtPath:self.path];
    if (!self.handle) return NO;
    uint8_t hdr[44]; memset(hdr, 0, sizeof(hdr));
    memcpy(hdr + 0, "RIFF", 4);
    memcpy(hdr + 8, "WAVE", 4);
    memcpy(hdr + 12, "fmt ", 4);
    uint32_t fmtSize = 16; memcpy(hdr + 16, &fmtSize, 4);
    uint16_t audioFormat = 1; memcpy(hdr + 20, &audioFormat, 2);
    memcpy(hdr + 22, &_channels, 2);
    uint32_t sr = (uint32_t)llround(self.sampleRate); memcpy(hdr + 24, &sr, 4);
    uint16_t bps = 16;
    uint32_t byteRate = sr * _channels * (bps / 8);
    uint16_t blockAlign = (uint16_t)(_channels * (bps / 8));
    memcpy(hdr + 28, &byteRate, 4);
    memcpy(hdr + 32, &blockAlign, 2);
    memcpy(hdr + 34, &bps, 2);
    memcpy(hdr + 36, "data", 4);
    @try { [self.handle writeData:[NSData dataWithBytes:hdr length:44]]; }
    @catch (__unused NSException *e) { return NO; }
    self.dataBytes = 0; self.open = YES; return YES;
}
- (void)writePCM16:(const void *)bytes length:(NSUInteger)length {
    if (!self.open || !bytes || length == 0 || !self.handle) return;
    NSUInteger n = length & ~(NSUInteger)1; if (!n) return;
    @try {
        [self.handle writeData:[NSData dataWithBytes:bytes length:n]];
        self.dataBytes += (uint32_t)n;
    } @catch (__unused NSException *e) {}
}
- (void)closeFile {
    if (!self.open || !self.handle) return;
    @try {
        uint32_t dataSize = self.dataBytes;
        uint32_t riffSize = 36 + dataSize;
        [self.handle seekToFileOffset:4];
        [self.handle writeData:[NSData dataWithBytes:&riffSize length:4]];
        [self.handle seekToFileOffset:40];
        [self.handle writeData:[NSData dataWithBytes:&dataSize length:4]];
        [self.handle synchronizeFile];
        [self.handle closeFile];
    } @catch (__unused NSException *e) {}
    self.handle = nil; self.open = NO;
}
- (void)dealloc { [self closeFile]; }
@end


static BOOL WCRWriteMixedPCM16Files(NSString *micPath, NSString *remotePath, NSString *outPath, double sampleRate) {
    NSData *mic = [NSData dataWithContentsOfFile:micPath];
    NSData *remote = [NSData dataWithContentsOfFile:remotePath];
    if (mic.length <= 44 && remote.length <= 44) return NO;
    const uint8_t *m = (const uint8_t *)mic.bytes;
    const uint8_t *r = (const uint8_t *)remote.bytes;
    NSUInteger mLen = mic.length > 44 ? mic.length - 44 : 0;
    NSUInteger rLen = remote.length > 44 ? remote.length - 44 : 0;
    mLen &= ~(NSUInteger)1;
    rLen &= ~(NSUInteger)1;
    NSUInteger outLen = MAX(mLen, rLen);
    if (outLen == 0) return NO;
    NSMutableData *pcm = [NSMutableData dataWithLength:outLen];
    int16_t *o = (int16_t *)pcm.mutableBytes;
    NSUInteger samples = outLen / 2;
    const int16_t *ms = (const int16_t *)(mLen ? (m + 44) : NULL);
    const int16_t *rs = (const int16_t *)(rLen ? (r + 44) : NULL);
    NSUInteger mSamples = mLen / 2;
    NSUInteger rSamples = rLen / 2;
    for (NSUInteger i = 0; i < samples; i++) {
        int32_t a = (i < mSamples && ms) ? ms[i] : 0;
        int32_t b = (i < rSamples && rs) ? rs[i] : 0;
        int32_t sum = a + b;
        if (sum > 32767) sum = 32767;
        if (sum < -32768) sum = -32768;
        o[i] = (int16_t)sum;
    }
    WCRWavWriter *w = [[WCRWavWriter alloc] initWithPath:outPath sampleRate:sampleRate channels:1];
    if (![w openFile]) return NO;
    [w writePCM16:pcm.bytes length:pcm.length];
    [w closeFile];
    return YES;
}

#pragma mark - Session

@interface WCRSessionManager : NSObject
@property (atomic, assign) BOOL recording;
@property (nonatomic, copy) NSString *sessionID;
@property (nonatomic, copy) NSString *sessionDir;
@property (nonatomic, strong) WCRWavWriter *micWriter;
@property (nonatomic, strong) WCRWavWriter *remoteWriter;
@property (nonatomic, strong) NSMutableDictionary *meta;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, assign) double sampleRate;
@property (nonatomic, assign) NSTimeInterval startedAt;
@property (nonatomic, assign) uint64_t micBytes;
@property (nonatomic, assign) uint64_t remoteBytes;
@end

@implementation WCRSessionManager
+ (instancetype)shared {
    static WCRSessionManager *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WCRSessionManager new]; });
    return s;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _ioQueue = dispatch_queue_create("com.blueskycrb.wcr.io", DISPATCH_QUEUE_SERIAL);
        _sampleRate = WCRPreferredSampleRate();
        _meta = [NSMutableDictionary dictionary];
    }
    return self;
}
- (NSString *)rootDir {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
    return [docs stringByAppendingPathComponent:@"WCallRecorder"];
}
- (NSString *)timestamp {
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    return [fmt stringFromDate:[NSDate date]];
}
- (void)beginInlineOnIOQueueWithReason:(NSString *)reason contactHint:(NSString *)hint sampleRate:(double)sr {
    if (self.recording || !WCREnabled()) return;
    self.sampleRate = sr > 0 ? sr : WCRPreferredSampleRate();
    NSString *contact = WCRSanitizeName(hint.length ? hint : @"unknown");
    self.sessionID = [NSString stringWithFormat:@"%@-%@", [self timestamp], contact];
    self.sessionDir = [[self rootDir] stringByAppendingPathComponent:self.sessionID];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.sessionDir withIntermediateDirectories:YES attributes:nil error:nil];
    self.micWriter = [[WCRWavWriter alloc] initWithPath:[self.sessionDir stringByAppendingPathComponent:@"mic.wav"] sampleRate:self.sampleRate channels:1];
    self.remoteWriter = [[WCRWavWriter alloc] initWithPath:[self.sessionDir stringByAppendingPathComponent:@"remote.wav"] sampleRate:self.sampleRate channels:1];
    [self.micWriter openFile];
    [self.remoteWriter openFile];
    self.startedAt = [NSDate date].timeIntervalSince1970;
    self.micBytes = 0;
    self.remoteBytes = 0;
    self.meta = [@{
        @"sessionID": self.sessionID ?: @"",
        @"reason": reason ?: @"",
        @"contactHint": hint ?: @"",
        @"sampleRate": @(self.sampleRate),
        @"startedAt": @(self.startedAt),
        @"path": self.sessionDir ?: @"",
        @"engine": @"HiveNoAds-WCallRecorder-free",
        @"targetWeChat": @"8.0.71",
        @"plugin": @"WCallRecorder-free",
        @"version": kWCRPluginVersion,
        @"auth": @"none"
    } mutableCopy];
    self.recording = YES;
    NSString *sid = self.sessionID;
    WCRInfo("session start reason=%@ id=%@", reason, sid);
    dispatch_async(dispatch_get_main_queue(), ^{
        WCRInstallLifecycle();
        WCRInstallManualAudioHooks();
        WCRAutoScanAudioHooks();
        if (!WCRBool(kWCRPrivateKey, NO)) WCRShowToast([NSString stringWithFormat:@"通话录音已开始\n%@", sid]);
        WCRUpdateIndicator(YES);
    });
}
- (void)beginWithReason:(NSString *)reason contactHint:(NSString *)hint sampleRate:(double)sr {
    dispatch_async(self.ioQueue, ^{ [self beginInlineOnIOQueueWithReason:reason contactHint:hint sampleRate:sr]; });
}
- (void)appendMic:(const void *)bytes length:(NSUInteger)len sampleRate:(double)sr {
    if (!bytes || !len) return;
    NSData *data = [NSData dataWithBytes:bytes length:len];
    dispatch_async(self.ioQueue, ^{
        if (!self.recording) [self beginInlineOnIOQueueWithReason:@"auto-mic" contactHint:@"auto" sampleRate:sr];
        if (!self.recording) return;
        [self.micWriter writePCM16:data.bytes length:data.length];
        self.micBytes += data.length;
    });
}
- (void)appendRemote:(const void *)bytes length:(NSUInteger)len sampleRate:(double)sr {
    if (!bytes || !len) return;
    NSData *data = [NSData dataWithBytes:bytes length:len];
    dispatch_async(self.ioQueue, ^{
        if (!self.recording) return;
        (void)sr;
        [self.remoteWriter writePCM16:data.bytes length:data.length];
        self.remoteBytes += data.length;
    });
}
- (void)endWithReason:(NSString *)reason {
    dispatch_async(self.ioQueue, ^{
        if (!self.recording) return;
        [self.micWriter closeFile]; [self.remoteWriter closeFile];
        NSString *micPath = [self.sessionDir stringByAppendingPathComponent:@"mic.wav"];
        NSString *remotePath = [self.sessionDir stringByAppendingPathComponent:@"remote.wav"];
        BOOL mixedOK = NO;
        if (WCRWriteMixed() && (self.micBytes > 0 || self.remoteBytes > 0)) {
            NSString *mixedPath = [self.sessionDir stringByAppendingPathComponent:@"mixed.wav"];
            mixedOK = WCRWriteMixedPCM16Files(micPath, remotePath, mixedPath, self.sampleRate);
        }
        self.micWriter = nil; self.remoteWriter = nil;
        self.meta[@"endedAt"] = @([NSDate date].timeIntervalSince1970);
        self.meta[@"endReason"] = reason ?: @"";
        self.meta[@"duration"] = @([NSDate date].timeIntervalSince1970 - self.startedAt);
        self.meta[@"micBytes"] = @(self.micBytes);
        self.meta[@"remoteBytes"] = @(self.remoteBytes);
        self.meta[@"mixed"] = @(mixedOK);
        self.meta[@"plugin"] = @"WCallRecorder-free";
        self.meta[@"version"] = kWCRPluginVersion;
        self.meta[@"auth"] = @"none";
        NSData *json = [NSJSONSerialization dataWithJSONObject:self.meta options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[self.sessionDir stringByAppendingPathComponent:@"meta.json"] atomically:YES];
        NSString *dir = [self.sessionDir copy];
        uint64_t micB = self.micBytes;
        uint64_t remoteB = self.remoteBytes;
        self.recording = NO; self.sessionID = nil; self.sessionDir = nil;
        self.micBytes = 0; self.remoteBytes = 0;
        WCRInfo("session end reason=%@ mic=%llu remote=%llu mixed=%d dir=%@", reason, micB, remoteB, mixedOK, dir);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!WCRBool(kWCRPrivateKey, NO)) {
                if (micB == 0 && remoteB == 0) {
                    WCRShowToast([NSString stringWithFormat:@"通话录音已结束(无音频)\n%@\n请用 Frida 补 WCRExtraAudioHooks", dir.lastPathComponent]);
                } else {
                    WCRShowToast([NSString stringWithFormat:@"通话录音已保存\n%@", dir.lastPathComponent]);
                }
            }
            WCRUpdateIndicator(NO);
        });
    });
}
@end


#pragma mark - UI

static __weak UIWindow *WCRIndicatorWindow = nil;

static void WCRShowToast(NSString *text) {
    if (text.length == 0) return;
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (key) break;
        }
    }
    if (!key) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        key = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    }
    if (!key) return;
    UILabel *lab = [UILabel new];
    lab.text = text; lab.textColor = UIColor.whiteColor;
    lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    lab.numberOfLines = 0; lab.textAlignment = NSTextAlignmentCenter;
    lab.layer.cornerRadius = 10; lab.layer.masksToBounds = YES;
    CGSize size = [lab sizeThatFits:CGSizeMake(key.bounds.size.width - 48, 200)];
    lab.frame = CGRectMake(24, key.bounds.size.height * 0.18, key.bounds.size.width - 48, size.height + 18);
    lab.alpha = 0; [key addSubview:lab];
    [UIView animateWithDuration:0.2 animations:^{ lab.alpha = 1; } completion:^(__unused BOOL f) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{ lab.alpha = 0; } completion:^(__unused BOOL f2) { [lab removeFromSuperview]; }];
        });
    }];
}

static void WCRUpdateIndicator(BOOL on) {
    if (!WCRBool(kWCRIndicatorKey, YES)) { if (WCRIndicatorWindow) WCRIndicatorWindow.hidden = YES; return; }
    if (!on) { if (WCRIndicatorWindow) WCRIndicatorWindow.hidden = YES; return; }
    UIWindow *win = WCRIndicatorWindow;
    if (!win) {
        CGRect frame = CGRectMake(12, 54, 72, 28);
        if (@available(iOS 13.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                    win = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)s];
                    win.frame = frame; break;
                }
            }
        }
        if (!win) win = [[UIWindow alloc] initWithFrame:frame];
        win.windowLevel = UIWindowLevelAlert + 100;
        win.backgroundColor = UIColor.clearColor;
        win.userInteractionEnabled = NO;
        UILabel *lab = [[UILabel alloc] initWithFrame:win.bounds];
        lab.text = @"REC"; lab.textAlignment = NSTextAlignmentCenter;
        lab.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        lab.textColor = UIColor.whiteColor;
        lab.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.9];
        lab.layer.cornerRadius = 14; lab.layer.masksToBounds = YES;
        [win addSubview:lab];
        WCRIndicatorWindow = win;
    }
    win.hidden = NO;
}

#pragma mark - Lazy rescan (WeChat 8.0.71 VoIP modules load on demand)

static void WCRAutoScanAudioHooks(void);
static void WCRInstallLifecycle(void);

static void WCROnCallMaybeStarted(void) {
    // VoIP dylibs/classes often appear only after first call entry on 8.0.71.
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (now - last < 1.0) return; // debounce
    last = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        WCRInstallLifecycle();
        WCRInstallManualAudioHooks();
        WCRAutoScanAudioHooks();
        // second pass: some units init slightly later
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            WCRInstallManualAudioHooks();
            WCRAutoScanAudioHooks();
        });
    });
}

#pragma mark - Lifecycle hooks

static void wcr_call_void(id self, SEL cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))WCRLookupOrig(self, cmd);
    WCROnCallMaybeStarted();
    NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
    [[WCRSessionManager shared] beginWithReason:reason contactHint:nil sampleRate:WCRPreferredSampleRate()];
    if (orig) orig(self, cmd);
}

static void wcr_call_id(id self, SEL cmd, id arg) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    WCROnCallMaybeStarted();
    NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
    [[WCRSessionManager shared] beginWithReason:reason contactHint:(WCRContactHintFromObject(arg) ?: WCRSafeDesc(arg)) sampleRate:WCRPreferredSampleRate()];
    if (orig) orig(self, cmd, arg);
}

static void wcr_call_id_id(id self, SEL cmd, id a, id b) {
    void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))WCRLookupOrig(self, cmd);
    WCROnCallMaybeStarted();
    NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
    NSString *hint = WCRContactHintFromObject(a) ?: WCRContactHintFromObject(b) ?: WCRSafeDesc(a) ?: WCRSafeDesc(b);
    [[WCRSessionManager shared] beginWithReason:reason contactHint:hint sampleRate:WCRPreferredSampleRate()];
    if (orig) orig(self, cmd, a, b);
}

static void wcr_call_id_id_id_id(id self, SEL cmd, id a, id b, id c, id d) {
    void (*orig)(id, SEL, id, id, id, id) = (void (*)(id, SEL, id, id, id, id))WCRLookupOrig(self, cmd);
    WCROnCallMaybeStarted();
    NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
    NSString *hint = WCRContactHintFromObject(a) ?: WCRContactHintFromObject(b) ?: WCRSafeDesc(a) ?: WCRSafeDesc(b) ?: WCRSafeDesc(c) ?: @"multitalk";
    [[WCRSessionManager shared] beginWithReason:reason contactHint:hint sampleRate:WCRPreferredSampleRate()];
    if (orig) orig(self, cmd, a, b, c, d);
}

static void wcr_call_room(id self, SEL cmd, id roomID, id roomKey) {
    void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))WCRLookupOrig(self, cmd);
    WCROnCallMaybeStarted();
    [[WCRSessionManager shared] beginWithReason:@"StartRecordAndPlayForVoIPWithRoomID:roomKey:"
                                   contactHint:(WCRSafeDesc(roomID) ?: @"voip-room")
                                    sampleRate:WCRPreferredSampleRate()];
    if (orig) orig(self, cmd, roomID, roomKey);
}

static void wcr_ilinkOpenWindow(id self, SEL cmd, id contact, id msg, BOOL isCaller, id from, BOOL startInApp, BOOL ear, BOOL audio) {
    void (*orig)(id, SEL, id, id, BOOL, id, BOOL, BOOL, BOOL) =
        (void (*)(id, SEL, id, id, BOOL, id, BOOL, BOOL, BOOL))WCRLookupOrig(self, cmd);
    WCROnCallMaybeStarted();
    [[WCRSessionManager shared] beginWithReason:@"ilinkOpenWindow"
                                   contactHint:(WCRContactHintFromObject(contact) ?: WCRSafeDesc(contact) ?: @"ilink")
                                    sampleRate:WCRPreferredSampleRate()];
    if (orig) orig(self, cmd, contact, msg, isCaller, from, startInApp, ear, audio);
}

static void wcr_stop(id self, SEL cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))WCRLookupOrig(self, cmd);
    [[WCRSessionManager shared] endWithReason:([NSString stringWithUTF8String:sel_getName(cmd)] ?: @"stop")];
    if (orig) orig(self, cmd);
}

#pragma mark - Audio hooks

typedef NS_ENUM(NSInteger, WCRTrack) {
    WCRTrackMic = 0,
    WCRTrackRemote = 1
};

static void WCRCapturePtr(id self, SEL cmd, WCRTrack track, const void *p, NSInteger n, double sr) {
    if (!p || n <= 0) return;
    if (track == WCRTrackMic) {
        [[WCRSessionManager shared] appendMic:p length:(NSUInteger)n sampleRate:sr];
    } else {
        [[WCRSessionManager shared] appendRemote:p length:(NSUInteger)n sampleRate:sr];
    }
    WCRLog("pcm %s %s n=%ld sr=%.0f", track == WCRTrackMic ? "mic" : "remote", sel_getName(cmd), (long)n, sr);
    (void)self;
}

static void WCRCaptureData(id self, SEL cmd, WCRTrack track, id data, double sr) {
    if ([data isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)data;
        WCRCapturePtr(self, cmd, track, d.bytes, (NSInteger)d.length, sr);
    }
}

static void wcr_mic_v_pi(id self, SEL cmd, void *p, int n) {
    void (*orig)(id, SEL, void *, int) = (void (*)(id, SEL, void *, int))WCRLookupOrig(self, cmd);
    WCRCapturePtr(self, cmd, WCRTrackMic, p, n, 0);
    if (orig) orig(self, cmd, p, n);
}
static void wcr_remote_v_pi(id self, SEL cmd, void *p, int n) {
    void (*orig)(id, SEL, void *, int) = (void (*)(id, SEL, void *, int))WCRLookupOrig(self, cmd);
    WCRCapturePtr(self, cmd, WCRTrackRemote, p, n, 0);
    if (orig) orig(self, cmd, p, n);
}

static void wcr_mic_v_pii(id self, SEL cmd, void *p, int n, int sr) {
    void (*orig)(id, SEL, void *, int, int) = (void (*)(id, SEL, void *, int, int))WCRLookupOrig(self, cmd);
    WCRCapturePtr(self, cmd, WCRTrackMic, p, n, (double)sr);
    if (orig) orig(self, cmd, p, n, sr);
}
static void wcr_remote_v_pii(id self, SEL cmd, void *p, int n, int sr) {
    void (*orig)(id, SEL, void *, int, int) = (void (*)(id, SEL, void *, int, int))WCRLookupOrig(self, cmd);
    WCRCapturePtr(self, cmd, WCRTrackRemote, p, n, (double)sr);
    if (orig) orig(self, cmd, p, n, sr);
}

static void wcr_mic_v_id(id self, SEL cmd, id data) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    WCRCaptureData(self, cmd, WCRTrackMic, data, 0);
    if (orig) orig(self, cmd, data);
}
static void wcr_remote_v_id(id self, SEL cmd, id data) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    WCRCaptureData(self, cmd, WCRTrackRemote, data, 0);
    if (orig) orig(self, cmd, data);
}

static IMP WCRPickAudioIMP(Method m, WCRTrack track) {
    if (!m) return NULL;
    unsigned argc = method_getNumberOfArguments(m);
    char t0[32] = {0}, t2[32] = {0};
    method_getReturnType(m, t0, sizeof(t0));
    if (argc >= 3) method_getArgumentType(m, 2, t2, sizeof(t2));
    if (t0[0] != 'v') return NULL;
    if (argc == 3 && t2[0] == '@') {
        return track == WCRTrackMic ? (IMP)wcr_mic_v_id : (IMP)wcr_remote_v_id;
    }
    if (argc == 4 && (t2[0] == '^' || t2[0] == '*')) {
        return track == WCRTrackMic ? (IMP)wcr_mic_v_pi : (IMP)wcr_remote_v_pi;
    }
    if (argc == 5 && (t2[0] == '^' || t2[0] == '*')) {
        return track == WCRTrackMic ? (IMP)wcr_mic_v_pii : (IMP)wcr_remote_v_pii;
    }
    return NULL;
}

static BOOL WCRHookAudioSelector(Class cls, SEL sel, WCRTrack track) {
    if (!cls || !sel) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP repl = WCRPickAudioIMP(m, track);
    if (!repl) {
        unsigned argc = method_getNumberOfArguments(m);
        if (argc == 4) repl = (track == WCRTrackMic) ? (IMP)wcr_mic_v_pi : (IMP)wcr_remote_v_pi;
        else if (argc == 3) repl = (track == WCRTrackMic) ? (IMP)wcr_mic_v_id : (IMP)wcr_remote_v_id;
        else if (argc >= 5) repl = (track == WCRTrackMic) ? (IMP)wcr_mic_v_pii : (IMP)wcr_remote_v_pii;
        else return NO;
    }
    return WCRHookInstance(cls, sel, repl);
}

static void WCRInstallLifecycle(void) {
    struct Item { const char *selName; IMP repl; int mode; } items[] = {
        {"StartRecordAndPlayForVoIP", (IMP)wcr_call_void, 0},
        {"StartRecordAndPlayForVoIPInterruptionRecovery", (IMP)wcr_call_void, 0},
        {"StartRecordAndPlayForMuTalk", (IMP)wcr_call_void, 0},
        {"StartRecordAndPlayForIlink:", (IMP)wcr_call_id, 1},
        {"StartRecordAndPlayForVoIPWithRoomID:roomKey:", (IMP)wcr_call_room, 3},
        {"StopForVoIP", (IMP)wcr_stop, 6},
        {"onEnterMultiTalk:", (IMP)wcr_call_id, 1},
        {"onInviteMultiTalk:", (IMP)wcr_call_id, 1},
        {"onAcceptSubCallMultiTalk:", (IMP)wcr_call_id, 1},
        {"onMultiTalkMainViewControllerAcceptWithGroup:", (IMP)wcr_call_id, 1},
        {"openAudioWindowWithContext:", (IMP)wcr_call_id, 1},
        {"openVideoWindowWithContext:", (IMP)wcr_call_id, 1},
        {"createMultiTalkWithContacts:withChatroomUsername:", (IMP)wcr_call_id_id, 2},
        {"joinMultiTalkWithGroup:roomId:roomKey:joinSuccessHandler:", (IMP)wcr_call_id_id_id_id, 4},
        {"ilinkOpenWindowWithContact:msgWrap:isCaller:from:startInApp:isEarMode:isAudioMode:", (IMP)wcr_ilinkOpenWindow, 5},
        {NULL, NULL, 0}
    };
    int hooked = 0;
    for (int i = 0; items[i].selName; i++) {
        SEL sel = sel_registerName(items[i].selName);
        Class cls = WCRFindClassForSelector(sel, YES);
        if (!cls) continue;
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        unsigned argc = method_getNumberOfArguments(m);
        if (items[i].mode == 5 && argc != 9) {
            WCRLog("skip ilinkOpenWindow arity=%u on %s", argc, class_getName(cls));
            continue;
        }
        if (items[i].mode == 4 && argc != 6) continue;
        if (WCRHookInstance(cls, sel, items[i].repl)) hooked++;
    }
    if (hooked > 0) {
        WCRInfo("lifecycle hooks newly installed: %d", hooked);
    }
}

static void WCRInstallManualAudioHooks(void) {
    for (NSArray<NSString *> *item in WCRExtraAudioHooks()) {
        if (item.count < 3) continue;
        Class cls = NSClassFromString(item[0]);
        SEL sel = NSSelectorFromString(item[1]);
        WCRTrack track = [item[2].lowercaseString isEqualToString:@"remote"] ? WCRTrackRemote : WCRTrackMic;
        WCRHookAudioSelector(cls, sel, track);
    }
}

static void WCRAutoScanAudioHooks(void) {
    // Common + 8.0.x/ilink-era buffer selector names.
    const char *micNames[] = {
        "onMicData:length:", "onMicData:length:sampleRate:",
        "deliverRecordedData:length:", "deliverRecordedData:length:sampleRate:",
        "inputAudioBuffer:length:", "inputAudioBuffer:length:sampleRate:",
        "onRecordData:length:", "onRecordData:length:sampleRate:",
        "writeMicPcm:length:", "writeMicPcm:length:sampleRate:",
        "receiveLocalAudioData:length:", "receiveLocalAudioData:length:sampleRate:",
        "InputPcmData:len:", "inputPcmData:len:", "inputPcmData:length:",
        "onLocalAudioFrame:length:", "onCapturedAudio:length:",
        "audioUnitRecordCallback:length:", "recordPcm:length:",
        "SendLocalAudioData:length:", "sendLocalAudioData:length:",
        "onLocalPcmData:length:", "PutMicData:length:", "putMicData:length:",
        "HandleRecordData:length:", "handleRecordData:length:",
        NULL
    };
    const char *remoteNames[] = {
        "onPlayData:length:", "onPlayData:length:sampleRate:",
        "deliverPlayedData:length:", "deliverPlayedData:length:sampleRate:",
        "outputAudioBuffer:length:", "outputAudioBuffer:length:sampleRate:",
        "onSpeakerData:length:", "onSpeakerData:length:sampleRate:",
        "writeRemotePcm:length:", "writeRemotePcm:length:sampleRate:",
        "receiveRemoteAudioData:length:", "receiveRemoteAudioData:length:sampleRate:",
        "OutputPcmData:len:", "outputPcmData:len:", "outputPcmData:length:",
        "onRemoteAudioFrame:length:", "onPlaybackAudio:length:",
        "audioUnitPlayCallback:length:", "playPcm:length:",
        "RecvRemoteAudioData:length:", "recvRemoteAudioData:length:",
        "onRemotePcmData:length:", "PutPlayData:length:", "putPlayData:length:",
        "HandlePlayData:length:", "handlePlayData:length:", "playOutPcm:length:",
        NULL
    };
    int hooked = 0;
    for (int i = 0; micNames[i]; i++) {
        SEL sel = sel_registerName(micNames[i]);
        Class cls = WCRFindClassForSelector(sel, YES);
        if (cls && WCRHookAudioSelector(cls, sel, WCRTrackMic)) hooked++;
    }
    for (int i = 0; remoteNames[i]; i++) {
        SEL sel = sel_registerName(remoteNames[i]);
        Class cls = WCRFindClassForSelector(sel, YES);
        if (cls && WCRHookAudioSelector(cls, sel, WCRTrackRemote)) hooked++;
    }
    // Also try preferred classes for any *Pcm*/*AudioData* own methods (narrow).
    for (NSString *cname in WCRPreferredClasses()) {
        Class cls = NSClassFromString(cname);
        if (!cls) continue;
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            const char *sn = sel_getName(sel);
            if (!sn) continue;
            BOOL isMic = (WCRCaseContains(sn, "mic") || WCRCaseContains(sn, "record") || WCRCaseContains(sn, "capture") || WCRCaseContains(sn, "local") || WCRCaseContains(sn, "input"));
            BOOL isRemote = (WCRCaseContains(sn, "play") || WCRCaseContains(sn, "speaker") || WCRCaseContains(sn, "remote") || WCRCaseContains(sn, "output") || WCRCaseContains(sn, "render"));
            BOOL isAudio = (WCRCaseContains(sn, "pcm") || WCRCaseContains(sn, "audio") || WCRCaseContains(sn, "buffer") || WCRCaseContains(sn, "frame"));
            if (!isAudio) continue;
            NSUInteger argc = method_getNumberOfArguments(methods[i]);
            if (argc < 4 || argc > 5) continue;
            if (isMic && !isRemote) {
                if (WCRHookAudioSelector(cls, sel, WCRTrackMic)) hooked++;
            } else if (isRemote && !isMic) {
                if (WCRHookAudioSelector(cls, sel, WCRTrackRemote)) hooked++;
            }
        }
        if (methods) free(methods);
    }
    if (hooked > 0) {
        atomic_store(&gWCRAudioHooksInstalled, 1);
        WCRInfo("audio hooks newly installed: %d", hooked);
    }
}

static void WCRObserveLifecycle(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
            [[WCRSessionManager shared] endWithReason:@"app-terminate"];
        }];
    });
}

__attribute__((constructor))
static void WCallRecorderInit(void) {
    @autoreleasepool {
        WCRInfo("free rewrite for WeChat 8.0.71 loaded (v%@, enabled=%d, no auth)", kWCRPluginVersion, WCREnabled());
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) { WCRInfo("disabled WCR.Enabled=0"); return; }
            @try {
                WCRInstallLifecycle();
                WCRInstallManualAudioHooks();
                WCRAutoScanAudioHooks();
                WCRObserveLifecycle();
                WCRInfo("ready for 8.0.71 => %@", [[WCRSessionManager shared] rootDir]);
            } @catch (NSException *e) {
                WCRInfo("install exception: %@", e);
            }
        });
        // Late pass: some VoIP classes appear only after services finish launching.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) return;
            @try {
                WCRInstallLifecycle();
                WCRAutoScanAudioHooks();
            } @catch (__unused NSException *e) {}
        });
    }
}


