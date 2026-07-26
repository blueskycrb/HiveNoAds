//
// WCallRecorder - free rewrite for HiveNoAds (no license / no auth)
// Target: WeChat 8.0.71 + Bootstrap/RootHide / TrollFools
// Pure ObjC runtime hooks, no license/auth. v0.5.0
// Features: remark filename, MP3 export (Shine), playback UI, hangup auto-stop
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <math.h>
#import <stdatomic.h>
#import <ctype.h>
#include "layer3.h"

#pragma mark - Config

static BOOL WCRVerboseFlag(void);
#define WCRLog(fmt, ...) do { if (WCRVerboseFlag()) NSLog(@"[WCallRecorder] " fmt, ##__VA_ARGS__); } while (0)
#define WCRInfo(fmt, ...) NSLog(@"[WCallRecorder] " fmt, ##__VA_ARGS__)

static NSString * const kWCREnabledKey    = @"WCR.Enabled";
static NSString * const kWCRIndicatorKey  = @"WCR.ShowIndicator";
static NSString * const kWCRFloatingKey   = @"WCR.ShowFloating";
static NSString * const kWCRPrivateKey    = @"WCR.PrivateMode";
static NSString * const kWCRSampleRateKey = @"WCR.SampleRate";
static NSString * const kWCRWriteMixedKey = @"WCR.WriteMixed";
static NSString * const kWCRVerboseKey    = @"WCR.Verbose";
static NSString * const kWCRPluginVersion = @"0.5.0";

static void WCRShowToast(NSString *text);
static void WCRUpdateIndicator(BOOL on);
static void WCRInstallLifecycle(void);
static void WCRInstallManualAudioHooks(void);
static void WCRAutoScanAudioHooks(void);
static void WCRAggressiveAudioScan(void);
static void WCRInstallUIEntries(void);
static void WCREnsureFloatingBall(void);
static void WCRPresentSettingsFrom(UIViewController *from);
static NSInteger WCRLifecycleHookCount(void);
static NSInteger WCRAudioHookCount(void);
static NSString *WCRLastSessionInfo(void);
static void WCRSetLastSessionInfo(NSString *info);

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
static void WCRSetBool(NSString *key, BOOL value) {
    [WCRDefaults() setBool:value forKey:key];
    [WCRDefaults() synchronize];
}
static double WCRPreferredSampleRate(void) {
    double v = [WCRDefaults() doubleForKey:kWCRSampleRateKey];
    if (v >= 8000.0 && v <= 48000.0) return v;
    return 16000.0;
}
static BOOL WCREnabled(void) { return WCRBool(kWCREnabledKey, YES); }
static BOOL WCRVerboseFlag(void) { return WCRBool(kWCRVerboseKey, NO); }
static BOOL WCRWriteMixed(void) { return WCRBool(kWCRWriteMixedKey, YES); }
static BOOL WCRShowFloatingEnabled(void) { return WCRBool(kWCRFloatingKey, YES); }

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
            @"CContactMgr", @"MMServiceCenter", @"MMContext",
            @"VOIPCSMgr", @"VoIPAudioService", @"IlinkAudioMgr",
            @"MTVoipMgr", @"VoipCXMgr", @"WCAudioUnit", @"MMAudioDataPipe"
        ];
    });
    return arr;
}

static atomic_int gWCRAudioHooksInstalled = 0;
static atomic_int gWCRLifecycleHooksInstalled = 0;
static atomic_int gWCRLastMicFrames = 0;
static atomic_int gWCRLastRemoteFrames = 0;
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
    if ([WCRHookedKeys() containsObject:key]) return NO;
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
    for (NSString *name in WCRPreferredClasses()) {
        Class cls = NSClassFromString(name);
        if (cls && class_getInstanceMethod(cls, sel)) return cls;
    }
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
             WCRCaseContains(name, "cloud") || WCRCaseContains(name, "live") ||
             WCRCaseContains(name, "device") || WCRCaseContains(name, "record"))) {
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
        } else if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            [out appendString:@"_"];
        } else if (c == '/' || c == '\\' || c == ':' || c == '*' || c == '?' ||
                   c == '"' || c == '<' || c == '>' || c == '|' || c == '.') {
            [out appendString:@"_"];
        } else if (c > 127) {
            // Keep CJK / unicode so remark names stay readable.
            [out appendFormat:@"%C", c];
        } else {
            [out appendString:@"_"];
        }
    }
    while ([out rangeOfString:@"__"].location != NSNotFound) {
        [out replaceOccurrencesOfString:@"__" withString:@"_" options:0 range:NSMakeRange(0, out.length)];
    }
    while (out.length && [out characterAtIndex:0] == '_') [out deleteCharactersInRange:NSMakeRange(0, 1)];
    while (out.length && [out characterAtIndex:out.length - 1] == '_') [out deleteCharactersInRange:NSMakeRange(out.length - 1, 1)];
    if (out.length == 0) return @"unknown";
    if (out.length > 64) return [out substringToIndex:64];
    return out;
}

static id WCRServiceOfClass(NSString *className) {
    if (className.length == 0) return nil;
    Class centerCls = NSClassFromString(@"MMServiceCenter");
    if (!centerCls) return nil;
    @try {
        id center = ((id(*)(id, SEL))objc_msgSend)(centerCls, NSSelectorFromString(@"defaultCenter"));
        if (!center) return nil;
        Class svcCls = NSClassFromString(className);
        if (!svcCls) return nil;
        SEL getSvc = NSSelectorFromString(@"getService:");
        if (![center respondsToSelector:getSvc]) return nil;
        return ((id(*)(id, SEL, Class))objc_msgSend)(center, getSvc, svcCls);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *WCRContactDisplayNameFromContact(id contact) {
    if (!contact) return nil;
    // Prefer remark (user note) over nick / wxid.
    NSString *remark = WCRPropString(contact, @[@"m_nsRemark", @"m_nsRemarkName", @"remark", @"remarkName"]);
    if (remark.length) return remark;
    NSString *nick = WCRPropString(contact, @[@"m_nsNickName", @"nickName", @"nickname", @"displayName", @"m_nsFullName"]);
    if (nick.length) return nick;
    NSString *usr = WCRPropString(contact, @[@"m_nsUsrName", @"userName", @"username"]);
    return usr;
}

static NSString *WCRResolveRemarkName(NSString *hintOrWxid) {
    if (hintOrWxid.length == 0) return nil;
    id mgr = WCRServiceOfClass(@"CContactMgr");
    if (mgr) {
        NSArray *sels = @[@"getContactByName:", @"getContactByUserName:", @"contactForUserName:"];
        for (NSString *selName in sels) {
            @try {
                SEL sel = NSSelectorFromString(selName);
                if (![mgr respondsToSelector:sel]) continue;
                id contact = ((id(*)(id, SEL, id))objc_msgSend)(mgr, sel, hintOrWxid);
                NSString *name = WCRContactDisplayNameFromContact(contact);
                if (name.length) return name;
            } @catch (__unused NSException *e) {}
        }
    }
    return hintOrWxid;
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
    NSString *remark = WCRPropString(obj, @[
        @"m_nsRemark", @"m_nsRemarkName", @"remark", @"remarkName"
    ]);
    if (remark.length) return remark;
    NSString *nick = WCRPropString(obj, @[
        @"m_nsNickName", @"m_nsUsrName", @"userName",
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

static UIWindow *WCRKeyWindow(void) {
    UIWindow *key = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
            if (key) break;
            if (!key) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (!w.hidden && w.alpha > 0.01) { key = w; break; }
                }
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
    return key;
}

static UIViewController *WCRTopViewController(void) {
    UIWindow *window = WCRKeyWindow();
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) {
        top = ((UINavigationController *)top).visibleViewController ?: top;
    } else if ([top isKindOfClass:[UITabBarController class]]) {
        top = ((UITabBarController *)top).selectedViewController ?: top;
        if ([top isKindOfClass:[UINavigationController class]]) {
            top = ((UINavigationController *)top).visibleViewController ?: top;
        }
    }
    return top;
}

static NSString *WCRLastSessionInfo(void) {
    return [WCRDefaults() stringForKey:@"WCR.LastSessionInfo"] ?: @"-";
}
static void WCRSetLastSessionInfo(NSString *info) {
    [WCRDefaults() setObject:(info ?: @"-") forKey:@"WCR.LastSessionInfo"];
    [WCRDefaults() synchronize];
}
static NSInteger WCRLifecycleHookCount(void) {
    return (NSInteger)atomic_load(&gWCRLifecycleHooksInstalled);
}
static NSInteger WCRAudioHookCount(void) {
    NSInteger n = 0;
    for (NSString *key in WCRHookedKeys()) {
        NSString *low = key.lowercaseString;
        if ([low containsString:@"startrecord"] || [low containsString:@"stopforvoip"] ||
            [low containsString:@"stoprecord"] || [low containsString:@"hangup"] ||
            [low containsString:@"endcall"] || [low containsString:@"cancelcall"] ||
            [low containsString:@"onenter"] || [low containsString:@"oninvite"] ||
            [low containsString:@"openaudio"] || [low containsString:@"openvideo"] ||
            [low containsString:@"ilinkopen"] || [low containsString:@"createmulti"] ||
            [low containsString:@"joinmulti"] || [low containsString:@"onaccept"] ||
            [low containsString:@"onmultitalk"] || [low containsString:@"viewdidappear"]) {
            continue;
        }
        if ([low containsString:@"pcm"] || [low containsString:@"audio"] ||
            [low containsString:@"mic"] || [low containsString:@"play"] ||
            [low containsString:@"buffer"] || [low containsString:@"frame"] ||
            [low containsString:@"record"] || [low containsString:@"speaker"] ||
            [low containsString:@"remote"] || [low containsString:@"local"]) {
            n++;
        }
    }
    if (n == 0) n = (NSInteger)atomic_load(&gWCRAudioHooksInstalled);
    return n;
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
    const int16_t *ms = (const int16_t *)(mLen ? m + 44 : NULL);
    const int16_t *rs = (const int16_t *)(rLen ? r + 44 : NULL);
    NSUInteger mSamples = mLen / 2;
    NSUInteger rSamples = rLen / 2;
    for (NSUInteger i = 0; i < samples; i++) {
        int32_t a = (i < mSamples && ms) ? ms[i] : 0;
        int32_t b = (i < rSamples && rs) ? rs[i] : 0;
        int32_t s = a + b;
        if (s > 32767) s = 32767;
        if (s < -32768) s = -32768;
        o[i] = (int16_t)s;
    }
    WCRWavWriter *w = [[WCRWavWriter alloc] initWithPath:outPath sampleRate:sampleRate channels:1];
    if (![w openFile]) return NO;
    [w writePCM16:pcm.bytes length:pcm.length];
    [w closeFile];
    return YES;
}

static NSData *WCRReadPCM16Body(NSString *wavPath, double *outSR) {
    NSData *wav = [NSData dataWithContentsOfFile:wavPath];
    if (wav.length <= 44) return nil;
    const uint8_t *b = (const uint8_t *)wav.bytes;
    if (outSR) {
        uint32_t sr = 0;
        memcpy(&sr, b + 24, 4);
        if (sr >= 8000 && sr <= 48000) *outSR = (double)sr;
    }
    NSUInteger body = (wav.length - 44) & ~(NSUInteger)1;
    if (body == 0) return nil;
    return [NSData dataWithBytes:b + 44 length:body];
}

static NSData *WCRMixPCM16Bodies(NSData *mic, NSData *remote) {
    NSUInteger mLen = mic.length & ~(NSUInteger)1;
    NSUInteger rLen = remote.length & ~(NSUInteger)1;
    NSUInteger outLen = MAX(mLen, rLen);
    if (outLen == 0) return nil;
    NSMutableData *pcm = [NSMutableData dataWithLength:outLen];
    int16_t *o = (int16_t *)pcm.mutableBytes;
    const int16_t *ms = (const int16_t *)(mLen ? mic.bytes : NULL);
    const int16_t *rs = (const int16_t *)(rLen ? remote.bytes : NULL);
    NSUInteger mSamples = mLen / 2;
    NSUInteger rSamples = rLen / 2;
    NSUInteger samples = outLen / 2;
    for (NSUInteger i = 0; i < samples; i++) {
        int32_t a = (i < mSamples && ms) ? ms[i] : 0;
        int32_t b = (i < rSamples && rs) ? rs[i] : 0;
        int32_t s = a + b;
        if (s > 32767) s = 32767;
        if (s < -32768) s = -32768;
        o[i] = (int16_t)s;
    }
    return pcm;
}

static int WCRPickShineSampleRate(double sr) {
    static const int table[] = {8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000};
    int best = 16000;
    double bestDiff = 1e18;
    for (size_t i = 0; i < sizeof(table)/sizeof(table[0]); i++) {
        double d = fabs((double)table[i] - sr);
        if (d < bestDiff) { bestDiff = d; best = table[i]; }
    }
    return best;
}

static int WCRPickShineBitrate(int sampleRate) {
    static const int cands[] = {32, 40, 48, 24, 16, 64, 56, 8};
    for (size_t i = 0; i < sizeof(cands)/sizeof(cands[0]); i++) {
        if (shine_check_config(sampleRate, cands[i]) >= 0) return cands[i];
    }
    return 32;
}

static BOOL WCREncodePCM16ToMP3(NSData *pcm, double sampleRate, NSString *outPath) {
    if (pcm.length < 2 || outPath.length == 0) return NO;
    int sr = WCRPickShineSampleRate(sampleRate > 0 ? sampleRate : 16000.0);
    int bitr = WCRPickShineBitrate(sr);
    if (shine_check_config(sr, bitr) < 0) {
        WCRInfo("shine config unsupported sr=%d br=%d", sr, bitr);
        return NO;
    }
    shine_config_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.wave.channels = PCM_MONO;
    cfg.wave.samplerate = sr;
    shine_set_config_mpeg_defaults(&cfg.mpeg);
    cfg.mpeg.mode = MONO;
    cfg.mpeg.bitr = bitr;
    cfg.mpeg.emph = NONE;
    cfg.mpeg.copyright = 0;
    cfg.mpeg.original = 1;
    shine_t s = shine_initialise(&cfg);
    if (!s) {
        WCRInfo("shine_initialise failed");
        return NO;
    }
    int samplesPerPass = shine_samples_per_pass(s);
    if (samplesPerPass <= 0 || samplesPerPass > SHINE_MAX_SAMPLES) {
        shine_close(s);
        return NO;
    }
    NSString *dir = [outPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    if ([[NSFileManager defaultManager] fileExistsAtPath:outPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    }
    if (![[NSFileManager defaultManager] createFileAtPath:outPath contents:nil attributes:nil]) {
        shine_close(s);
        return NO;
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:outPath];
    if (!fh) {
        shine_close(s);
        return NO;
    }
    const int16_t *src = (const int16_t *)pcm.bytes;
    NSUInteger totalSamples = (pcm.length / 2);
    NSUInteger offset = 0;
    int16_t frame[SHINE_MAX_SAMPLES];
    BOOL ok = YES;
    @try {
        while (offset < totalSamples) {
            NSUInteger remain = totalSamples - offset;
            NSUInteger n = MIN((NSUInteger)samplesPerPass, remain);
            memset(frame, 0, sizeof(int16_t) * (size_t)samplesPerPass);
            memcpy(frame, src + offset, n * sizeof(int16_t));
            offset += n;
            int written = 0;
            unsigned char *mp3 = shine_encode_buffer_interleaved(s, frame, &written);
            if (mp3 && written > 0) {
                [fh writeData:[NSData dataWithBytes:mp3 length:(NSUInteger)written]];
            }
        }
        int written = 0;
        unsigned char *tail = shine_flush(s, &written);
        if (tail && written > 0) {
            [fh writeData:[NSData dataWithBytes:tail length:(NSUInteger)written]];
        }
        [fh synchronizeFile];
        [fh closeFile];
    } @catch (__unused NSException *e) {
        ok = NO;
        @try { [fh closeFile]; } @catch (__unused NSException *e2) {}
    }
    shine_close(s);
    if (!ok) return NO;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:nil];
    unsigned long long sz = [attrs fileSize];
    WCRInfo("mp3 encoded path=%@ bytes=%llu sr=%d br=%d", outPath, (unsigned long long)sz, sr, bitr);
    return sz > 0;
}

static BOOL WCRExportSessionMP3(NSString *sessionDir, NSString *displayName, double sampleRate, NSString **outMP3Path) {
    if (outMP3Path) *outMP3Path = nil;
    if (sessionDir.length == 0) return NO;
    NSString *micPath = [sessionDir stringByAppendingPathComponent:@"mic.wav"];
    NSString *remotePath = [sessionDir stringByAppendingPathComponent:@"remote.wav"];
    double sr = sampleRate;
    NSData *mic = WCRReadPCM16Body(micPath, &sr) ?: [NSData data];
    NSData *remote = WCRReadPCM16Body(remotePath, &sr) ?: [NSData data];
    NSData *mixed = WCRMixPCM16Bodies(mic, remote);
    if (mixed.length < 2) return NO;
    NSString *mp3InSession = [sessionDir stringByAppendingPathComponent:@"call.mp3"];
    if (!WCREncodePCM16ToMP3(mixed, sr > 0 ? sr : sampleRate, mp3InSession)) return NO;
    NSString *root = [sessionDir stringByDeletingLastPathComponent];
    // Prefer full session id (remark_timestamp) so names stay unique and readable.
    NSString *safe = WCRSanitizeName(sessionDir.lastPathComponent.length ? sessionDir.lastPathComponent : (displayName ?: @"call"));
    NSString *rootCopy = [root stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp3", safe]];
    [[NSFileManager defaultManager] removeItemAtPath:rootCopy error:nil];
    NSError *err = nil;
    BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:mp3InSession toPath:rootCopy error:&err];
    if (!copied) {
        WCRInfo("mp3 root copy failed: %@", err);
        rootCopy = mp3InSession;
    }
    if (outMP3Path) *outMP3Path = rootCopy;
    return YES;
}

static BOOL WCRPCMBufferLooksSilent(const void *bytes, NSUInteger len) {
    if (!bytes || len < 2) return YES;
    const int16_t *s = (const int16_t *)bytes;
    NSUInteger n = len / 2;
    NSUInteger step = n > 512 ? (n / 512) : 1;
    int32_t peak = 0;
    for (NSUInteger i = 0; i < n; i += step) {
        int32_t v = s[i];
        if (v < 0) v = -v;
        if (v > peak) peak = v;
        if (peak >= 180) return NO;
    }
    return peak < 180;
}

#pragma mark - Session manager

@interface WCRSessionManager : NSObject
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, assign) BOOL recording;
@property (nonatomic, copy) NSString *sessionID;
@property (nonatomic, copy) NSString *sessionDir;
@property (nonatomic, copy) NSString *contactDisplayName;
@property (nonatomic, strong) WCRWavWriter *micWriter;
@property (nonatomic, strong) WCRWavWriter *remoteWriter;
@property (nonatomic, assign) double sampleRate;
@property (nonatomic, assign) uint64_t micBytes;
@property (nonatomic, assign) uint64_t remoteBytes;
@property (nonatomic, assign) NSTimeInterval lastPCMAt;
@property (nonatomic, assign) NSTimeInterval lastVoiceAt;
@property (nonatomic, assign) BOOL everHadPCM;
@property (nonatomic, strong) dispatch_source_t idleTimer;
@property (nonatomic, strong) NSMutableDictionary *meta;
+ (instancetype)shared;
- (NSString *)rootDir;
- (BOOL)isRecording;
- (void)beginWithReason:(NSString *)reason contactHint:(NSString *)hint sampleRate:(double)sr;
- (void)appendMic:(const void *)bytes length:(NSUInteger)len sampleRate:(double)sr;
- (void)appendRemote:(const void *)bytes length:(NSUInteger)len sampleRate:(double)sr;
- (void)endWithReason:(NSString *)reason;
- (NSArray<NSDictionary *> *)listSessions;
- (NSString *)bestPlayablePathForSessionDir:(NSString *)dir;
@end

@implementation WCRSessionManager
+ (instancetype)shared {
    static WCRSessionManager *mgr;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ mgr = [WCRSessionManager new]; });
    return mgr;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        _ioQueue = dispatch_queue_create("com.blueskycrb.wcallrecorder.io", DISPATCH_QUEUE_SERIAL);
        _sampleRate = 16000.0;
        _meta = [NSMutableDictionary dictionary];
    }
    return self;
}
- (BOOL)isRecording { return self.recording; }
- (NSString *)rootDir {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"WCallRecorder"];
}
- (void)stopIdleWatchdog {
    if (self.idleTimer) {
        dispatch_source_cancel(self.idleTimer);
        self.idleTimer = nil;
    }
}
- (void)startIdleWatchdog {
    [self stopIdleWatchdog];
    __weak typeof(self) weakSelf = self;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.ioQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self.recording) return;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (!self.everHadPCM) {
            if (self.lastPCMAt > 0 && (now - self.lastPCMAt) > 90.0) {
                WCRInfo("idle watchdog: no-pcm-timeout");
                [self endWithReason:@"no-pcm-timeout"];
            }
            return;
        }
        NSTimeInterval ref = MAX(self.lastVoiceAt, self.lastPCMAt);
        if (ref > 0 && (now - ref) > 10.0) {
            WCRInfo("idle watchdog: idle-silence (%.1fs)", now - ref);
            [self endWithReason:@"idle-silence"];
        }
    });
    dispatch_resume(timer);
    self.idleTimer = timer;
}
- (void)beginInlineOnIOQueueWithReason:(NSString *)reason contactHint:(NSString *)hint sampleRate:(double)sr {
    if (!WCREnabled()) return;
    if (self.recording) return;
    double useSR = (sr >= 8000.0 && sr <= 48000.0) ? sr : WCRPreferredSampleRate();
    self.sampleRate = useSR;
    NSString *resolved = WCRResolveRemarkName(hint.length ? hint : reason) ?: (hint.length ? hint : reason);
    self.contactDisplayName = resolved;
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *ts = [fmt stringFromDate:[NSDate date]];
    NSString *safeHint = WCRSanitizeName(resolved.length ? resolved : @"unknown");
    NSString *sid = [NSString stringWithFormat:@"%@_%@", safeHint, ts];
    NSString *dir = [[self rootDir] stringByAppendingPathComponent:sid];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    self.sessionID = sid;
    self.sessionDir = dir;
    self.micWriter = [[WCRWavWriter alloc] initWithPath:[dir stringByAppendingPathComponent:@"mic.wav"] sampleRate:useSR channels:1];
    self.remoteWriter = [[WCRWavWriter alloc] initWithPath:[dir stringByAppendingPathComponent:@"remote.wav"] sampleRate:useSR channels:1];
    [self.micWriter openFile];
    [self.remoteWriter openFile];
    self.micBytes = 0; self.remoteBytes = 0;
    self.everHadPCM = NO;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    self.lastPCMAt = now;
    self.lastVoiceAt = now;
    atomic_store(&gWCRLastMicFrames, 0);
    atomic_store(&gWCRLastRemoteFrames, 0);
    self.meta = [@{
        @"id": sid ?: @"",
        @"reason": reason ?: @"",
        @"hint": hint ?: @"",
        @"displayName": resolved ?: @"",
        @"sampleRate": @(useSR),
        @"startedAt": @(now),
        @"version": kWCRPluginVersion,
        @"auth": @"none",
        @"wechatTarget": @"8.0.71",
        @"format": @"mp3"
    } mutableCopy];
    self.recording = YES;
    [self startIdleWatchdog];
    WCRInfo("session begin id=%@ reason=%@ name=%@ sr=%.0f", sid, reason, resolved, useSR);
    WCRSetLastSessionInfo([NSString stringWithFormat:@"recording %@", sid]);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            WCRInstallLifecycle();
            WCRInstallManualAudioHooks();
            WCRAutoScanAudioHooks();
            if (WCRVerboseFlag()) WCRAggressiveAudioScan();
        } @catch (__unused NSException *e) {}
        if (!WCRBool(kWCRPrivateKey, NO)) WCRShowToast([NSString stringWithFormat:@"通话录音已开始\n%@", sid]);
        WCRUpdateIndicator(YES);
        WCREnsureFloatingBall();
    });
}
- (void)beginWithReason:(NSString *)reason contactHint:(NSString *)hint sampleRate:(double)sr {
    dispatch_async(self.ioQueue, ^{ [self beginInlineOnIOQueueWithReason:reason contactHint:hint sampleRate:sr]; });
}
- (void)appendMic:(const void *)bytes length:(NSUInteger)len sampleRate:(double)sr {
    if (!bytes || !len) return;
    NSData *data = [NSData dataWithBytes:bytes length:len];
    BOOL silent = WCRPCMBufferLooksSilent(bytes, len);
    dispatch_async(self.ioQueue, ^{
        if (!self.recording) [self beginInlineOnIOQueueWithReason:@"auto-mic" contactHint:@"auto" sampleRate:sr];
        if (!self.recording) return;
        [self.micWriter writePCM16:data.bytes length:data.length];
        self.micBytes += data.length;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        self.lastPCMAt = now;
        self.everHadPCM = YES;
        if (!silent) self.lastVoiceAt = now;
        atomic_fetch_add(&gWCRLastMicFrames, 1);
    });
}
- (void)appendRemote:(const void *)bytes length:(NSUInteger)len sampleRate:(double)sr {
    if (!bytes || !len) return;
    NSData *data = [NSData dataWithBytes:bytes length:len];
    BOOL silent = WCRPCMBufferLooksSilent(bytes, len);
    dispatch_async(self.ioQueue, ^{
        if (!self.recording) [self beginInlineOnIOQueueWithReason:@"auto-remote" contactHint:@"auto" sampleRate:sr];
        if (!self.recording) return;
        (void)sr;
        [self.remoteWriter writePCM16:data.bytes length:data.length];
        self.remoteBytes += data.length;
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        self.lastPCMAt = now;
        self.everHadPCM = YES;
        if (!silent) self.lastVoiceAt = now;
        atomic_fetch_add(&gWCRLastRemoteFrames, 1);
    });
}
- (void)endWithReason:(NSString *)reason {
    dispatch_async(self.ioQueue, ^{
        if (!self.recording) return;
        [self stopIdleWatchdog];
        [self.micWriter closeFile]; [self.remoteWriter closeFile];
        NSString *micPath = [self.sessionDir stringByAppendingPathComponent:@"mic.wav"];
        NSString *remotePath = [self.sessionDir stringByAppendingPathComponent:@"remote.wav"];
        BOOL mixedOK = NO;
        if (WCRWriteMixed() && (self.micBytes > 0 || self.remoteBytes > 0)) {
            NSString *mixedPath = [self.sessionDir stringByAppendingPathComponent:@"mixed.wav"];
            mixedOK = WCRWriteMixedPCM16Files(micPath, remotePath, mixedPath, self.sampleRate);
        }
        NSString *mp3Path = nil;
        BOOL mp3OK = NO;
        if (self.micBytes > 0 || self.remoteBytes > 0) {
            mp3OK = WCRExportSessionMP3(self.sessionDir, self.contactDisplayName ?: self.sessionID, self.sampleRate, &mp3Path);
        }
        self.micWriter = nil; self.remoteWriter = nil;
        self.meta[@"endedAt"] = @([NSDate date].timeIntervalSince1970);
        self.meta[@"endReason"] = reason ?: @"";
        self.meta[@"micBytes"] = @(self.micBytes);
        self.meta[@"remoteBytes"] = @(self.remoteBytes);
        self.meta[@"mixed"] = @(mixedOK);
        self.meta[@"mp3"] = @(mp3OK);
        if (mp3Path.length) self.meta[@"mp3Path"] = mp3Path;
        self.meta[@"lifecycleHooks"] = @(WCRLifecycleHookCount());
        self.meta[@"audioHooks"] = @(WCRAudioHookCount());
        self.meta[@"auth"] = @"none";
        NSData *json = [NSJSONSerialization dataWithJSONObject:self.meta options:NSJSONWritingPrettyPrinted error:nil];
        [json writeToFile:[self.sessionDir stringByAppendingPathComponent:@"meta.json"] atomically:YES];
        NSString *dir = [self.sessionDir copy];
        uint64_t micB = self.micBytes;
        uint64_t remoteB = self.remoteBytes;
        NSString *sid = [self.sessionID copy];
        NSString *mp3Show = [mp3Path.lastPathComponent copy] ?: @"-";
        self.recording = NO; self.sessionID = nil; self.sessionDir = nil;
        self.contactDisplayName = nil;
        self.micBytes = 0; self.remoteBytes = 0;
        self.everHadPCM = NO;
        self.lastPCMAt = 0; self.lastVoiceAt = 0;
        WCRInfo("session end reason=%@ mic=%llu remote=%llu mixed=%d mp3=%d dir=%@", reason, micB, remoteB, mixedOK, mp3OK, dir);
        NSString *info = [NSString stringWithFormat:@"%@ mic=%llu remote=%llu mp3=%@", sid ?: dir.lastPathComponent, micB, remoteB, mp3Show];
        WCRSetLastSessionInfo(info);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!WCRBool(kWCRPrivateKey, NO)) {
                if (micB == 0 && remoteB == 0) {
                    WCRShowToast([NSString stringWithFormat:@"通话录音已结束(无音频)\n%@\n打开悬浮球查看诊断，或用 Frida 补钩", dir.lastPathComponent]);
                } else if (mp3OK) {
                    WCRShowToast([NSString stringWithFormat:@"通话录音已保存(MP3)\n%@", mp3Show]);
                } else {
                    WCRShowToast([NSString stringWithFormat:@"通话录音已保存\n%@", dir.lastPathComponent]);
                }
            }
            WCRUpdateIndicator(NO);
            WCREnsureFloatingBall();
        });
    });
}
- (NSArray<NSDictionary *> *)listSessions {
    NSString *root = [self rootDir];
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSMutableArray *items = [NSMutableArray array];
    for (NSString *name in names) {
        // Skip root-level loose mp3 files in list (shown via session dirs).
        if ([name.lowercaseString hasSuffix:@".mp3"]) continue;
        NSString *dir = [root stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSString *metaPath = [dir stringByAppendingPathComponent:@"meta.json"];
        NSDictionary *meta = nil;
        NSData *data = [NSData dataWithContentsOfFile:metaPath];
        if (data) meta = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:dir error:nil];
        NSString *play = [self bestPlayablePathForSessionDir:dir];
        [items addObject:@{
            @"name": name,
            @"path": dir,
            @"playPath": play ?: @"",
            @"meta": meta ?: @{},
            @"date": attrs[NSFileModificationDate] ?: [NSDate distantPast]
        }];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"date"] compare:a[@"date"]];
    }];
    return items;
}
- (NSString *)bestPlayablePathForSessionDir:(NSString *)dir {
    if (dir.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *meta = nil;
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"meta.json"]];
    if (data) meta = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *mp3Meta = [meta isKindOfClass:[NSDictionary class]] ? meta[@"mp3Path"] : nil;
    if ([mp3Meta isKindOfClass:[NSString class]] && [fm fileExistsAtPath:mp3Meta]) return mp3Meta;
    NSArray *cands = @[
        [dir stringByAppendingPathComponent:@"call.mp3"],
        [dir stringByAppendingPathComponent:@"mixed.wav"],
        [dir stringByAppendingPathComponent:@"remote.wav"],
        [dir stringByAppendingPathComponent:@"mic.wav"],
    ];
    for (NSString *p in cands) {
        if ([fm fileExistsAtPath:p]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:p error:nil];
            if ([attrs fileSize] > 0) return p;
        }
    }
    return nil;
}
@end

#pragma mark - UI helpers

static __weak UIWindow *WCRIndicatorWindow = nil;
static UIWindow *WCRFloatingWindow = nil;
static UILabel *WCRFloatingLabel = nil;

static void WCRShowToast(NSString *text) {
    if (text.length == 0) return;
    void (^show)(void) = ^{
        UIWindow *key = WCRKeyWindow();
        if (!key) return;
        UILabel *lab = [UILabel new];
        lab.text = text; lab.textColor = UIColor.whiteColor;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        lab.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        lab.numberOfLines = 0; lab.textAlignment = NSTextAlignmentCenter;
        lab.layer.cornerRadius = 10; lab.layer.masksToBounds = YES;
        CGFloat maxW = key.bounds.size.width - 48;
        CGSize size = [lab sizeThatFits:CGSizeMake(maxW, 220)];
        lab.frame = CGRectMake(24, MAX(80, key.bounds.size.height * 0.16), maxW, size.height + 18);
        lab.alpha = 0; [key addSubview:lab];
        [UIView animateWithDuration:0.2 animations:^{ lab.alpha = 1; } completion:^(__unused BOOL f) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ lab.alpha = 0; } completion:^(__unused BOOL f2) { [lab removeFromSuperview]; }];
            });
        }];
    };
    if ([NSThread isMainThread]) show();
    else dispatch_async(dispatch_get_main_queue(), show);
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
        win.windowLevel = UIWindowLevelAlert + 120;
        win.backgroundColor = UIColor.clearColor;
        win.userInteractionEnabled = NO;
        win.hidden = NO;
        UILabel *lab = [[UILabel alloc] initWithFrame:win.bounds];
        lab.text = @"REC"; lab.textAlignment = NSTextAlignmentCenter;
        lab.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
        lab.textColor = UIColor.whiteColor;
        lab.backgroundColor = [[UIColor systemRedColor] colorWithAlphaComponent:0.92];
        lab.layer.cornerRadius = 14; lab.layer.masksToBounds = YES;
        [win addSubview:lab];
        WCRIndicatorWindow = win;
    }
    win.hidden = NO;
}

@interface WCRFloatTarget : NSObject
- (void)tap;
- (void)pan:(UIPanGestureRecognizer *)g;
@end
@implementation WCRFloatTarget
- (void)tap { WCRPresentSettingsFrom(WCRTopViewController()); }
- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v) return;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointMake(0, 0) inView:v.superview];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGRect b = v.superview.bounds;
        CGFloat x = MIN(MAX(v.center.x, 36), b.size.width - 36);
        CGFloat y = MIN(MAX(v.center.y, 80), b.size.height - 80);
        [UIView animateWithDuration:0.18 animations:^{ v.center = CGPointMake(x, y); }];
        if (WCRFloatingWindow) {
            CGRect f = WCRFloatingWindow.frame;
            f.origin = CGPointMake(x - f.size.width / 2.0, y - f.size.height / 2.0);
            WCRFloatingWindow.frame = f;
            v.center = CGPointMake(f.size.width / 2.0, f.size.height / 2.0);
        }
    }
}
@end

static WCRFloatTarget *WCRFloatTargetObj(void) {
    static WCRFloatTarget *t;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ t = [WCRFloatTarget new]; });
    return t;
}

static void WCREnsureFloatingBall(void) {
    if (!WCRShowFloatingEnabled() || !WCREnabled()) {
        if (WCRFloatingWindow) WCRFloatingWindow.hidden = YES;
        return;
    }
    void (^build)(void) = ^{
        if (!WCRFloatingWindow) {
            CGRect frame = CGRectMake(UIScreen.mainScreen.bounds.size.width - 78, 180, 64, 64);
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                    if (s.activationState == UISceneActivationStateForegroundActive && [s isKindOfClass:[UIWindowScene class]]) {
                        WCRFloatingWindow = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)s];
                        WCRFloatingWindow.frame = frame;
                        break;
                    }
                }
            }
            if (!WCRFloatingWindow) WCRFloatingWindow = [[UIWindow alloc] initWithFrame:frame];
            WCRFloatingWindow.windowLevel = UIWindowLevelAlert + 90;
            WCRFloatingWindow.backgroundColor = UIColor.clearColor;
            WCRFloatingWindow.userInteractionEnabled = YES;
            UIViewController *root = [UIViewController new];
            root.view.backgroundColor = UIColor.clearColor;
            UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
            ball.backgroundColor = [[UIColor colorWithRed:0.12 green:0.55 blue:0.98 alpha:1] colorWithAlphaComponent:0.94];
            ball.layer.cornerRadius = 32;
            ball.layer.shadowColor = [UIColor blackColor].CGColor;
            ball.layer.shadowOpacity = 0.25;
            ball.layer.shadowRadius = 6;
            ball.layer.shadowOffset = CGSizeMake(0, 3);
            WCRFloatingLabel = [[UILabel alloc] initWithFrame:ball.bounds];
            WCRFloatingLabel.textAlignment = NSTextAlignmentCenter;
            WCRFloatingLabel.numberOfLines = 2;
            WCRFloatingLabel.textColor = UIColor.whiteColor;
            WCRFloatingLabel.font = [UIFont boldSystemFontOfSize:11];
            WCRFloatingLabel.text = @"录音\n插件";
            [ball addSubview:WCRFloatingLabel];
            [root.view addSubview:ball];
            WCRFloatingWindow.rootViewController = root;
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:WCRFloatTargetObj() action:@selector(tap)];
            UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:WCRFloatTargetObj() action:@selector(pan:)];
            [ball addGestureRecognizer:tap];
            [ball addGestureRecognizer:pan];
        }
        BOOL rec = [[WCRSessionManager shared] isRecording];
        if (WCRFloatingLabel) WCRFloatingLabel.text = rec ? @"REC\n中" : @"录音\n插件";
        UIView *ball = WCRFloatingWindow.rootViewController.view.subviews.firstObject;
        if (ball) {
            ball.backgroundColor = rec
                ? [[UIColor systemRedColor] colorWithAlphaComponent:0.94]
                : [[UIColor colorWithRed:0.12 green:0.55 blue:0.98 alpha:1] colorWithAlphaComponent:0.94];
        }
        WCRFloatingWindow.hidden = NO;
    };
    if ([NSThread isMainThread]) build();
    else dispatch_async(dispatch_get_main_queue(), build);
}

#pragma mark - Settings UI

@interface WCRSettingViewController : UITableViewController <AVAudioPlayerDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *sessions;
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UISwitch *floatSwitch;
@property (nonatomic, strong) UISwitch *indicatorSwitch;
@property (nonatomic, strong) UISwitch *privateSwitch;
@property (nonatomic, strong) UISwitch *mixedSwitch;
@property (nonatomic, strong) UISwitch *verboseSwitch;
@property (nonatomic, strong) AVAudioPlayer *player;
@property (nonatomic, copy) NSString *playingPath;
@end

@implementation WCRSettingViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"WCallRecorder";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.tableView.estimatedRowHeight = 48;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    [self reloadData];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}
- (void)close {
    if (self.navigationController.presentingViewController) {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        [self.navigationController popViewControllerAnimated:YES];
    }
}
- (void)reloadData {
    self.sessions = [[WCRSessionManager shared] listSessions];
    [self.tableView reloadData];
}
- (UISwitch *)mkSwitch:(BOOL)on action:(SEL)sel {
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    return sw;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 6;
    if (section == 1) return 5;
    if (section == 2) return 4;
    return MAX((NSInteger)self.sessions.count, (NSInteger)1);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"开关";
    if (section == 1) return @"状态 / 诊断";
    if (section == 2) return @"操作";
    return @"最近录音 (Documents/WCallRecorder)";
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) {
        return @"若通话结束提示无音频：说明 PCM 钩子未命中。可点“重新扫描钩子”，或用 Frida 脚本补 WCRExtraAudioHooks。";
    }
    if (section == 3) return [[WCRSessionManager shared] rootDir];
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"c";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.text = nil;
    cell.textLabel.text = nil;

    if (indexPath.section == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"启用录音";
            if (!_enabledSwitch) _enabledSwitch = [self mkSwitch:WCREnabled() action:@selector(onEnabled:)];
            _enabledSwitch.on = WCREnabled();
            cell.accessoryView = _enabledSwitch;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"显示悬浮球";
            if (!_floatSwitch) _floatSwitch = [self mkSwitch:WCRShowFloatingEnabled() action:@selector(onFloat:)];
            _floatSwitch.on = WCRShowFloatingEnabled();
            cell.accessoryView = _floatSwitch;
        } else if (indexPath.row == 2) {
            cell.textLabel.text = @"通话中 REC 指示";
            if (!_indicatorSwitch) _indicatorSwitch = [self mkSwitch:WCRBool(kWCRIndicatorKey, YES) action:@selector(onIndicator:)];
            _indicatorSwitch.on = WCRBool(kWCRIndicatorKey, YES);
            cell.accessoryView = _indicatorSwitch;
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"隐私模式(隐藏Toast)";
            if (!_privateSwitch) _privateSwitch = [self mkSwitch:WCRBool(kWCRPrivateKey, NO) action:@selector(onPrivate:)];
            _privateSwitch.on = WCRBool(kWCRPrivateKey, NO);
            cell.accessoryView = _privateSwitch;
        } else if (indexPath.row == 4) {
            cell.textLabel.text = @"结束时写 mixed.wav";
            if (!_mixedSwitch) _mixedSwitch = [self mkSwitch:WCRWriteMixed() action:@selector(onMixed:)];
            _mixedSwitch.on = WCRWriteMixed();
            cell.accessoryView = _mixedSwitch;
        } else {
            cell.textLabel.text = @"详细日志 (Verbose)";
            if (!_verboseSwitch) _verboseSwitch = [self mkSwitch:WCRVerboseFlag() action:@selector(onVerbose:)];
            _verboseSwitch.on = WCRVerboseFlag();
            cell.accessoryView = _verboseSwitch;
        }
        return cell;
    }

    if (indexPath.section == 1) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        BOOL rec = [[WCRSessionManager shared] isRecording];
        if (indexPath.row == 0) {
            cell.textLabel.text = [NSString stringWithFormat:@"插件版本 %@", kWCRPluginVersion];
            cell.detailTextLabel.text = @"免费无授权 · 目标 WeChat 8.0.71";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = [NSString stringWithFormat:@"生命周期钩子: %ld", (long)WCRLifecycleHookCount()];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"音频钩子约: %ld  (总hook=%lu)", (long)WCRAudioHookCount(), (unsigned long)WCRHookedKeys().count];
        } else if (indexPath.row == 2) {
            cell.textLabel.text = rec ? @"当前: 录音中" : @"当前: 空闲";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"PCM帧 mic=%d remote=%d",
                                         atomic_load(&gWCRLastMicFrames), atomic_load(&gWCRLastRemoteFrames)];
        } else if (indexPath.row == 3) {
            cell.textLabel.text = @"最近会话";
            cell.detailTextLabel.text = WCRLastSessionInfo();
        } else {
            cell.textLabel.text = @"保存目录";
            cell.detailTextLabel.text = [[WCRSessionManager shared] rootDir];
        }
        return cell;
    }

    if (indexPath.section == 2) {
        if (indexPath.row == 0) cell.textLabel.text = @"重新扫描钩子";
        else if (indexPath.row == 1) cell.textLabel.text = [[WCRSessionManager shared] isRecording] ? @"强制结束当前录音" : @"强制开始测试会话";
        else if (indexPath.row == 2) cell.textLabel.text = @"复制保存路径";
        else cell.textLabel.text = @"刷新列表";
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (self.sessions.count == 0) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = @"暂无录音";
        cell.detailTextLabel.text = @"打一通微信语音/视频后回来刷新";
        return cell;
    }
    NSDictionary *item = self.sessions[indexPath.row];
    NSDictionary *meta = item[@"meta"] ?: @{};
    NSString *title = meta[@"displayName"] ?: item[@"name"];
    cell.textLabel.text = title;
    NSString *playPath = item[@"playPath"] ?: @"";
    NSString *fmt = @"?";
    if ([playPath.lowercaseString hasSuffix:@".mp3"]) fmt = @"mp3";
    else if ([playPath.lowercaseString hasSuffix:@".wav"]) fmt = @"wav";
    else if ([meta[@"mp3"] boolValue]) fmt = @"mp3";
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · mic=%@ remote=%@ · %@",
                                 fmt,
                                 meta[@"micBytes"] ?: @"?",
                                 meta[@"remoteBytes"] ?: @"?",
                                 meta[@"endReason"] ?: (meta[@"reason"] ?: @"-")];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            WCRInstallLifecycle();
            WCRInstallManualAudioHooks();
            WCRAutoScanAudioHooks();
            WCRAggressiveAudioScan();
            WCRShowToast([NSString stringWithFormat:@"已扫描\n生命周期=%ld 音频约=%ld",
                          (long)WCRLifecycleHookCount(), (long)WCRAudioHookCount()]);
            [self reloadData];
        } else if (indexPath.row == 1) {
            if ([[WCRSessionManager shared] isRecording]) {
                [[WCRSessionManager shared] endWithReason:@"manual-stop"];
            } else {
                [[WCRSessionManager shared] beginWithReason:@"manual-start" contactHint:@"manual" sampleRate:WCRPreferredSampleRate()];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self reloadData];
                WCREnsureFloatingBall();
            });
        } else if (indexPath.row == 2) {
            UIPasteboard.generalPasteboard.string = [[WCRSessionManager shared] rootDir];
            WCRShowToast(@"路径已复制");
        } else {
            [self reloadData];
        }
        return;
    }
    if (indexPath.section == 3 && self.sessions.count > 0) {
        NSDictionary *item = self.sessions[indexPath.row];
        [self presentSessionActions:item];
    }
}
- (void)stopPlayback {
    if (self.player) {
        [self.player stop];
        self.player = nil;
    }
    self.playingPath = nil;
}
- (void)playPath:(NSString *)path {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        WCRShowToast(@"没有可播放文件");
        return;
    }
    [self stopPlayback];
    NSError *err = nil;
    @try {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
        [[AVAudioSession sharedInstance] setActive:YES error:nil];
    } @catch (__unused NSException *e) {}
    AVAudioPlayer *player = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (!player || err) {
        WCRShowToast([NSString stringWithFormat:@"播放失败\n%@", err.localizedDescription ?: @"unknown"]);
        return;
    }
    player.delegate = self;
    self.player = player;
    self.playingPath = path;
    [player prepareToPlay];
    if ([player play]) {
        WCRShowToast([NSString stringWithFormat:@"正在播放\n%@", path.lastPathComponent]);
    } else {
        WCRShowToast(@"播放失败");
        [self stopPlayback];
    }
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    (void)player; (void)flag;
    self.player = nil;
    self.playingPath = nil;
    WCRShowToast(@"播放结束");
}
- (void)sharePath:(NSString *)path fromView:(UIView *)sourceView {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        WCRShowToast(@"文件不存在");
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = sourceView ?: self.view;
        avc.popoverPresentationController.sourceRect = sourceView ? sourceView.bounds : CGRectMake(self.view.bounds.size.width/2, 80, 1, 1);
    }
    [self presentViewController:avc animated:YES completion:nil];
}
- (void)deleteSessionItem:(NSDictionary *)item {
    NSString *dir = item[@"path"];
    if (dir.length == 0) return;
    NSString *playPath = item[@"playPath"];
    if (self.playingPath.length && ([self.playingPath hasPrefix:dir] || [self.playingPath isEqualToString:playPath])) {
        [self stopPlayback];
    }
    NSError *err = nil;
    [[NSFileManager defaultManager] removeItemAtPath:dir error:&err];
    NSDictionary *meta = item[@"meta"] ?: @{};
    NSString *mp3Path = meta[@"mp3Path"];
    if ([mp3Path isKindOfClass:[NSString class]] && mp3Path.length && [[NSFileManager defaultManager] fileExistsAtPath:mp3Path]) {
        [[NSFileManager defaultManager] removeItemAtPath:mp3Path error:nil];
    }
    if (err) WCRShowToast([NSString stringWithFormat:@"删除失败\n%@", err.localizedDescription]);
    else WCRShowToast(@"已删除");
    [self reloadData];
}
- (void)presentSessionActions:(NSDictionary *)item {
    NSString *dir = item[@"path"] ?: @"";
    NSString *playPath = item[@"playPath"];
    if (![playPath isKindOfClass:[NSString class]] || playPath.length == 0) {
        playPath = [[WCRSessionManager shared] bestPlayablePathForSessionDir:dir] ?: @"";
    }
    NSString *title = item[@"name"] ?: @"录音";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:(playPath.length ? playPath.lastPathComponent : dir)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    if (playPath.length) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"播放" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [weakSelf playPath:playPath];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"分享" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [weakSelf sharePath:playPath fromView:weakSelf.view];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        UIPasteboard.generalPasteboard.string = playPath.length ? playPath : dir;
        WCRShowToast(@"路径已复制");
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [weakSelf deleteSessionItem:item];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.view;
        sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, 120, 1, 1);
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)onEnabled:(UISwitch *)sw {
    WCRSetBool(kWCREnabledKey, sw.isOn);
    if (!sw.isOn && [[WCRSessionManager shared] isRecording]) {
        [[WCRSessionManager shared] endWithReason:@"disabled"];
    }
    WCREnsureFloatingBall();
}
- (void)onFloat:(UISwitch *)sw {
    WCRSetBool(kWCRFloatingKey, sw.isOn);
    WCREnsureFloatingBall();
}
- (void)onIndicator:(UISwitch *)sw { WCRSetBool(kWCRIndicatorKey, sw.isOn); }
- (void)onPrivate:(UISwitch *)sw { WCRSetBool(kWCRPrivateKey, sw.isOn); }
- (void)onMixed:(UISwitch *)sw { WCRSetBool(kWCRWriteMixedKey, sw.isOn); }
- (void)onVerbose:(UISwitch *)sw { WCRSetBool(kWCRVerboseKey, sw.isOn); }
@end

static void WCRPresentSettingsFrom(UIViewController *from) {
    WCRSettingViewController *vc = [WCRSettingViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    UIViewController *host = from ?: WCRTopViewController();
    if (!host) {
        WCRShowToast(@"暂时无法打开设置页，请稍后再点悬浮球");
        return;
    }
    [host presentViewController:nav animated:YES completion:nil];
}

@interface WCRBarTarget : NSObject
@property (nonatomic, weak) UIViewController *host;
- (void)open;
@end
@implementation WCRBarTarget
- (void)open { WCRPresentSettingsFrom(self.host); }
@end

static char kWCRBarTargetKey;
static void (*WCR_orig_setting_viewDidAppear)(id, SEL, BOOL) = NULL;
static void WCR_repl_setting_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (WCR_orig_setting_viewDidAppear) WCR_orig_setting_viewDidAppear(self, _cmd, animated);
    @try {
        UIViewController *vc = (UIViewController *)self;
        if (![vc isKindOfClass:[UIViewController class]]) return;
        for (UIBarButtonItem *item in vc.navigationItem.rightBarButtonItems ?: @[]) {
            if (item.tag == 0x57435231) return;
        }
        WCRBarTarget *target = [WCRBarTarget new];
        target.host = vc;
        objc_setAssociatedObject(vc, &kWCRBarTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"录音"
                                                                style:UIBarButtonItemStylePlain
                                                               target:target
                                                               action:@selector(open)];
        btn.tag = 0x57435231;
        NSMutableArray *items = [NSMutableArray arrayWithArray:vc.navigationItem.rightBarButtonItems ?: @[]];
        [items insertObject:btn atIndex:0];
        vc.navigationItem.rightBarButtonItems = items;
    } @catch (__unused NSException *e) {}
}

static void WCRTryRegisterPlugin(void) {
    static dispatch_once_t onceToken;
    static BOOL registered = NO;
    if (registered) return;
    @try {
        Class mgrCls = NSClassFromString(@"WCPluginsMgr");
        if (!mgrCls) return;
        SEL shared = sel_registerName("sharedInstance");
        id mgr = nil;
        if ([mgrCls respondsToSelector:shared]) {
            mgr = ((id(*)(id, SEL))objc_msgSend)(mgrCls, shared);
        } else {
            SEL def = sel_registerName("defaultMgr");
            if ([mgrCls respondsToSelector:def]) {
                mgr = ((id(*)(id, SEL))objc_msgSend)(mgrCls, def);
            }
        }
        if (!mgr) return;
        SEL reg = sel_registerName("registerControllerWithTitle:version:controller:");
        if (![mgr respondsToSelector:reg]) return;
        dispatch_once(&onceToken, ^{
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(mgr, reg, @"WCallRecorder \u901a\u8bdd\u5f55\u97f3", kWCRPluginVersion, @"WCRSettingViewController");
            registered = YES;
            WCRInfo("registered into WCPluginsMgr once");
        });
    } @catch (__unused NSException *e) {}
}

static void WCRInstallUIEntries(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class setting = NSClassFromString(@"NewSettingViewController");
        if (setting) {
            SEL appear = @selector(viewDidAppear:);
            if ([setting instancesRespondToSelector:appear]) {
                Method m = class_getInstanceMethod(setting, appear);
                if (m) {
                    WCR_orig_setting_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
                    WCRHookInstance(setting, appear, (IMP)WCR_repl_setting_viewDidAppear);
                }
            }
        }
        WCRTryRegisterPlugin();
    });
    // Retry once-guarded registration if WCPluginsMgr was late to load.
    WCRTryRegisterPlugin();
}

#pragma mark - Lazy rescan (WeChat 8.0.71 VoIP modules load on demand)

static void WCROnCallMaybeStarted(void) {
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (now - last < 1.5) return;
    last = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            // Crash-safe path: only known/safe hooks during live call accept.
            WCRInstallLifecycle();
            WCRInstallManualAudioHooks();
            WCRAutoScanAudioHooks();
            if (WCRVerboseFlag()) WCRAggressiveAudioScan();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    WCRInstallManualAudioHooks();
                    WCRAutoScanAudioHooks();
                    if (WCRVerboseFlag()) WCRAggressiveAudioScan();
                } @catch (__unused NSException *e) {}
            });
        } @catch (__unused NSException *e) {}
    });
}

#pragma mark - Lifecycle hooks

static void wcr_call_void(id self, SEL cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))WCRLookupOrig(self, cmd);
    @try {
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
            [[WCRSessionManager shared] beginWithReason:reason contactHint:nil sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd);
}

static void wcr_call_id(id self, SEL cmd, id arg) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    @try {
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
            [[WCRSessionManager shared] beginWithReason:reason contactHint:(WCRContactHintFromObject(arg) ?: WCRSafeDesc(arg)) sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd, arg);
}

static void wcr_call_id_id(id self, SEL cmd, id a, id b) {
    void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))WCRLookupOrig(self, cmd);
    @try {
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
            NSString *hint = WCRContactHintFromObject(a) ?: WCRContactHintFromObject(b) ?: WCRSafeDesc(a);
            [[WCRSessionManager shared] beginWithReason:reason contactHint:hint sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd, a, b);
}

static void wcr_call_room(id self, SEL cmd, id roomID, id roomKey) {
    void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))WCRLookupOrig(self, cmd);
    @try {
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *hint = [NSString stringWithFormat:@"room-%@", WCRSafeDesc(roomID) ?: @"?"];
            [[WCRSessionManager shared] beginWithReason:@"StartRecordAndPlayForVoIPWithRoomID" contactHint:hint sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd, roomID, roomKey);
}

static void wcr_call_join(id self, SEL cmd, id group, id roomId, id roomKey, id handler) {
    void (*orig)(id, SEL, id, id, id, id) = (void (*)(id, SEL, id, id, id, id))WCRLookupOrig(self, cmd);
    @try {
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *hint = WCRContactHintFromObject(group) ?: WCRSafeDesc(group) ?: @"join";
            [[WCRSessionManager shared] beginWithReason:@"joinMultiTalk" contactHint:hint sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd, group, roomId, roomKey, handler);
}

static void wcr_stop(id self, SEL cmd) {
    void (*orig)(id, SEL) = (void (*)(id, SEL))WCRLookupOrig(self, cmd);
    [[WCRSessionManager shared] endWithReason:([NSString stringWithUTF8String:sel_getName(cmd)] ?: @"stop")];
    if (orig) orig(self, cmd);
}
static void wcr_stop_id(id self, SEL cmd, id arg) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    [[WCRSessionManager shared] endWithReason:([NSString stringWithUTF8String:sel_getName(cmd)] ?: @"stop")];
    if (orig) orig(self, cmd, arg);
}

#pragma mark - Audio hooks

typedef NS_ENUM(NSInteger, WCRTrack) {
    WCRTrackMic = 0,
    WCRTrackRemote = 1
};

static void WCRCapturePtr(id self, SEL cmd, WCRTrack track, const void *p, NSInteger n, double sr) {
    if (!p || n <= 0) return;
    if (n > 2 * 1024 * 1024) return;
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
static void wcr_mic_v_idi(id self, SEL cmd, id data, int n) {
    void (*orig)(id, SEL, id, int) = (void (*)(id, SEL, id, int))WCRLookupOrig(self, cmd);
    if ([data isKindOfClass:[NSData class]]) WCRCaptureData(self, cmd, WCRTrackMic, data, 0);
    else if (data) WCRCapturePtr(self, cmd, WCRTrackMic, (__bridge const void *)data, n, 0);
    if (orig) orig(self, cmd, data, n);
}
static void wcr_remote_v_idi(id self, SEL cmd, id data, int n) {
    void (*orig)(id, SEL, id, int) = (void (*)(id, SEL, id, int))WCRLookupOrig(self, cmd);
    if ([data isKindOfClass:[NSData class]]) WCRCaptureData(self, cmd, WCRTrackRemote, data, 0);
    else if (data) WCRCapturePtr(self, cmd, WCRTrackRemote, (__bridge const void *)data, n, 0);
    if (orig) orig(self, cmd, data, n);
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
    if (argc == 4 && t2[0] == '@') {
        return track == WCRTrackMic ? (IMP)wcr_mic_v_idi : (IMP)wcr_remote_v_idi;
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
    // Strict match only. Loose fallbacks corrupt the stack and crash on answer.
    IMP repl = WCRPickAudioIMP(m, track);
    if (!repl) return NO;
    return WCRHookInstance(cls, sel, repl);
}

static void WCRInstallLifecycle(void) {
    // Only hook known selectors with exact argc. Wrong ABI here crashes on accept.
    struct Item { const char *selName; IMP repl; int argcHint; } items[] = {
        {"StartRecordAndPlayForVoIP", (IMP)wcr_call_void, 0},
        {"StartRecordAndPlayForVoIPInterruptionRecovery", (IMP)wcr_call_void, 0},
        {"StartRecordAndPlayForMuTalk", (IMP)wcr_call_void, 0},
        {"StartRecordAndPlayForIlink:", (IMP)wcr_call_id, 1},
        {"StartRecordAndPlayForVoIPWithRoomID:roomKey:", (IMP)wcr_call_room, 2},
        {"StopForVoIP", (IMP)wcr_stop, 0},
        // Prefer VoIP-specific stop selectors only (generic hangup/reject is crash-prone).
        {"StopRecordAndPlayForVoIP", (IMP)wcr_stop, 0},
        {"StopRecordAndPlayForMuTalk", (IMP)wcr_stop, 0},
        {"StopRecordAndPlayForIlink", (IMP)wcr_stop, 0},
        {"StopRecordAndPlayForIlink:", (IMP)wcr_stop_id, 1},
        {"StopRecordAndPlayForVoIPInterruptionRecovery", (IMP)wcr_stop, 0},
        {"onMultiTalkMainViewControllerHangup", (IMP)wcr_stop, 0},
        {"onMultiTalkMainViewControllerReject", (IMP)wcr_stop, 0},
        {"onMultiTalkMainViewControllerCancel", (IMP)wcr_stop, 0},
        {"onMultiTalkMainViewControllerHangup:", (IMP)wcr_stop_id, 1},
        {"onMultiTalkMainViewControllerReject:", (IMP)wcr_stop_id, 1},
        {"onMultiTalkMainViewControllerCancel:", (IMP)wcr_stop_id, 1},
        {"onMultiTalkMainViewControllerCloseWindow", (IMP)wcr_stop, 0},
        {"onMultiTalkMainViewControllerCloseWindow:", (IMP)wcr_stop_id, 1},
        {"onEnterMultiTalk:", (IMP)wcr_call_id, 1},
        {"onInviteMultiTalk:", (IMP)wcr_call_id, 1},
        {"onAcceptSubCallMultiTalk:", (IMP)wcr_call_id, 1},
        {"onMultiTalkMainViewControllerAcceptWithGroup:", (IMP)wcr_call_id, 1},
        {"createMultiTalkWithContacts:withChatroomUsername:", (IMP)wcr_call_id_id, 2},
        {"joinMultiTalkWithGroup:roomId:roomKey:joinSuccessHandler:", (IMP)wcr_call_join, 4},
        {"openAudioWindowWithContext:", (IMP)wcr_call_id, 1},
        {"openVideoWindowWithContext:", (IMP)wcr_call_id, 1},
        {NULL, NULL, 0}
    };
    int hooked = 0;
    for (int i = 0; items[i].selName; i++) {
        SEL sel = sel_registerName(items[i].selName);
        NSMutableArray *classes = [NSMutableArray array];
        for (NSString *name in WCRPreferredClasses()) {
            Class cls = NSClassFromString(name);
            if (cls && class_getInstanceMethod(cls, sel)) [classes addObject:cls];
        }
        if (classes.count == 0) {
            Class cls = WCRFindClassForSelector(sel, YES);
            if (cls) [classes addObject:cls];
        }
        for (Class cls in classes) {
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            unsigned argc = method_getNumberOfArguments(m);
            // self + _cmd + args
            if (argc != (unsigned)(2 + items[i].argcHint)) {
                WCRLog("skip lifecycle %s on %s argc=%u expected=%d",
                       items[i].selName, class_getName(cls), argc, 2 + items[i].argcHint);
                continue;
            }
            char ret[8] = {0};
            method_getReturnType(m, ret, sizeof(ret));
            if (ret[0] != 'v') continue;
            if (WCRHookInstance(cls, sel, items[i].repl)) hooked++;
        }
    }
    if (hooked > 0) {
        atomic_fetch_add(&gWCRLifecycleHooksInstalled, hooked);
        WCRInfo("lifecycle hooks newly installed: %d (total keys=%lu)", hooked, (unsigned long)WCRHookedKeys().count);
    }
}

static void WCRInstallManualAudioHooks(void) {
    int hooked = 0;
    for (NSArray *item in WCRExtraAudioHooks()) {
        if (item.count < 3) continue;
        Class cls = NSClassFromString(item[0]);
        SEL sel = NSSelectorFromString(item[1]);
        NSString *track = [item[2] lowercaseString];
        if (!cls || !sel) continue;
        if (WCRHookAudioSelector(cls, sel, [track isEqualToString:@"remote"] ? WCRTrackRemote : WCRTrackMic)) hooked++;
    }
    if (hooked > 0) {
        atomic_store(&gWCRAudioHooksInstalled, 1);
        WCRInfo("manual audio hooks installed: %d", hooked);
    }
}

static void WCRAutoScanAudioHooks(void) {
    const char *micNames[] = {
        "onMicData:length:", "onMicData:length:sampleRate:",
        "deliverRecordedData:length:", "deliverRecordedData:length:sampleRate:",
        "inputAudioBuffer:length:", "inputAudioBuffer:length:sampleRate:",
        "onRecordData:length:", "onRecordData:length:sampleRate:",
        "writeLocalPcm:length:", "writeLocalPcm:length:sampleRate:",
        "sendLocalAudioData:length:", "SendLocalAudioData:length:",
        "onLocalPcmData:length:", "PutMicData:length:", "putMicData:length:",
        "HandleRecordData:length:", "handleRecordData:length:",
        "audioUnitRecordCallback:length:", "recordPcm:length:",
        "onCaptureData:length:", "capturePcm:length:",
        "InputPcmData:len:", "inputPcmData:len:", "inputPcmData:length:",
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
            if (argc < 3 || argc > 5) continue;
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

static void WCRAggressiveAudioScan(void) {
    // Disabled by default: broad class scans easily hook wrong ABI methods and crash WeChat.
    // Enable only with Verbose diagnostics when hunting new PCM selectors.
    if (!WCRVerboseFlag()) return;

    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (now - last < 2.0) return;
    last = now;

    int hooked = 0;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cname = class_getName(cls);
        if (!cname) continue;
        if (!(WCRCaseContains(cname, "voip") || WCRCaseContains(cname, "audio") ||
              WCRCaseContains(cname, "ilink") || WCRCaseContains(cname, "talk") ||
              WCRCaseContains(cname, "conf") || WCRCaseContains(cname, "device") ||
              WCRCaseContains(cname, "record") || WCRCaseContains(cname, "pcm") ||
              WCRCaseContains(cname, "live") || WCRCaseContains(cname, "cloud") ||
              WCRCaseContains(cname, "mt") || WCRCaseContains(cname, "auaudio"))) {
            continue;
        }
        unsigned int mcount = 0;
        Method *methods = class_copyMethodList(cls, &mcount);
        for (unsigned int j = 0; j < mcount; j++) {
            Method m = methods[j];
            SEL sel = method_getName(m);
            const char *sn = sel_getName(sel);
            if (!sn) continue;
            unsigned argc = method_getNumberOfArguments(m);
            if (argc < 3 || argc > 5) continue;

            BOOL nameHit = (WCRCaseContains(sn, "pcm") || WCRCaseContains(sn, "audio") ||
                            WCRCaseContains(sn, "buffer") || WCRCaseContains(sn, "frame") ||
                            WCRCaseContains(sn, "sample") || WCRCaseContains(sn, "mic") ||
                            WCRCaseContains(sn, "play") || WCRCaseContains(sn, "record") ||
                            WCRCaseContains(sn, "speaker") || WCRCaseContains(sn, "capture") ||
                            WCRCaseContains(sn, "input") || WCRCaseContains(sn, "output") ||
                            WCRCaseContains(sn, "remote") || WCRCaseContains(sn, "local"));
            if (!nameHit) continue;

            char ret[8] = {0};
            method_getReturnType(m, ret, sizeof(ret));
            if (ret[0] != 'v') continue;
            char t2[16] = {0};
            method_getArgumentType(m, 2, t2, sizeof(t2));
            if (!(t2[0] == '^' || t2[0] == '*' || t2[0] == '@')) continue;

            BOOL isMic = (WCRCaseContains(sn, "mic") || WCRCaseContains(sn, "record") ||
                          WCRCaseContains(sn, "capture") || WCRCaseContains(sn, "local") ||
                          WCRCaseContains(sn, "input") || WCRCaseContains(sn, "send"));
            BOOL isRemote = (WCRCaseContains(sn, "play") || WCRCaseContains(sn, "speaker") ||
                             WCRCaseContains(sn, "remote") || WCRCaseContains(sn, "output") ||
                             WCRCaseContains(sn, "recv") || WCRCaseContains(sn, "render") ||
                             WCRCaseContains(sn, "playback"));
            WCRTrack track = WCRTrackMic;
            if (isRemote && !isMic) track = WCRTrackRemote;
            else if (isMic && !isRemote) track = WCRTrackMic;
            else if (isRemote) track = WCRTrackRemote;
            else if (!isMic && !isRemote) continue;
            if (WCRHookAudioSelector(cls, sel, track)) hooked++;
        }
        if (methods) free(methods);
    }
    free(classes);
    if (hooked > 0) {
        atomic_store(&gWCRAudioHooksInstalled, 1);
        WCRInfo("aggressive audio hooks newly installed: %d", hooked);
    }
}

static void WCRObserveLifecycle(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
            [[WCRSessionManager shared] endWithReason:@"app-terminate"];
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
            WCREnsureFloatingBall();
            // Registration is once-guarded; safe to retry if WCPluginsMgr appears late.
            WCRTryRegisterPlugin();
        }];
    });
}

__attribute__((constructor))
static void WCallRecorderInit(void) {
    @autoreleasepool {
        WCRInfo("free rewrite for WeChat 8.0.71 loaded (v%@, enabled=%d, no auth)", kWCRPluginVersion, WCREnabled());
        dispatch_async(dispatch_get_main_queue(), ^{
            WCRInstallUIEntries();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) { WCRInfo("disabled WCR.Enabled=0"); return; }
            @try {
                WCRInstallUIEntries();
                WCRInstallLifecycle();
                WCRInstallManualAudioHooks();
                WCRAutoScanAudioHooks();
                WCRObserveLifecycle();
                WCREnsureFloatingBall();
                if (!WCRBool(kWCRPrivateKey, NO)) {
                    WCRShowToast([NSString stringWithFormat:@"WCallRecorder 已加载 v%@\n点右下角蓝色悬浮球打开", kWCRPluginVersion]);
                }
                WCRInfo("ready for 8.0.71 => %@ (life=%ld audio~%ld)", [[WCRSessionManager shared] rootDir], (long)WCRLifecycleHookCount(), (long)WCRAudioHookCount());
            } @catch (NSException *e) {
                WCRInfo("install exception: %@", e);
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) return;
            @try {
                WCRInstallUIEntries();
                WCRInstallLifecycle();
                WCRInstallManualAudioHooks();
                WCRAutoScanAudioHooks();
                if (WCRVerboseFlag()) WCRAggressiveAudioScan();
                WCREnsureFloatingBall();
            } @catch (__unused NSException *e) {}
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) return;
            @try {
                WCRTryRegisterPlugin();
                WCRInstallLifecycle();
                WCRInstallManualAudioHooks();
                WCRAutoScanAudioHooks();
                if (WCRVerboseFlag()) WCRAggressiveAudioScan();
                WCREnsureFloatingBall();
            } @catch (__unused NSException *e) {}
        });
    }
}