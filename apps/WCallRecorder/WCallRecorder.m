//
// WCallRecorder - free rewrite for HiveNoAds (no license / no auth)
// Target: WeChat 8.0.71 + Bootstrap/RootHide / TrollFools
// Pure ObjC runtime hooks, no license/auth. v0.5.7
// v0.5.7: answer-call auto-start + post-load AU pointer rebind + setMode hooks
// v0.5.6: commercial-style ObjC lifecycle + dyld rescan + AVAudioSession detect/stop + remark scrape
// v0.5.5: Fix probe compile, re-rebind AU on new images, remark rename,
//         hangup UI detect, commercial-style extra ObjC sinks, playable MP3 guard
// Features: remark filename, MP3 export (Shine), playback UI, hangup auto-stop
// v0.5.4: Chained-fixup AudioUnit rebind + signature probe on audio classes + live rescan
// v0.5.3: Learn commercial ObjC-only capture model — runtime PCM probe + persist hooks,
//         MSHookMessageEx when present, chained-fixup fishhook, better remark naming
// v0.5.2: Substrate-free fishhook AudioUnit PCM, remark naming fix, hook diagnostics
// v0.5.1: Ilink contact resolve, empty-file play guard, AudioUnit PCM capture, faster idle end
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <string.h>
#import <math.h>
#import <stdatomic.h>
#import <ctype.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#include "layer3.h"

#pragma mark - Config

static BOOL WCRVerboseFlag(void);
static NSUserDefaults *WCRDefaults(void);
static BOOL WCRBool(NSString *key, BOOL fallback);
#define WCRLog(fmt, ...) do { if (WCRVerboseFlag()) NSLog(@"[WCallRecorder] " fmt, ##__VA_ARGS__); } while (0)
#define WCRInfo(fmt, ...) NSLog(@"[WCallRecorder] " fmt, ##__VA_ARGS__)

static NSString * const kWCREnabledKey    = @"WCR.Enabled";
static NSString * const kWCRIndicatorKey  = @"WCR.ShowIndicator";
static NSString * const kWCRFloatingKey   = @"WCR.ShowFloating";
static NSString * const kWCRPrivateKey    = @"WCR.PrivateMode";
static NSString * const kWCRSampleRateKey = @"WCR.SampleRate";
static NSString * const kWCRWriteMixedKey = @"WCR.WriteMixed";
static NSString * const kWCRVerboseKey    = @"WCR.Verbose";
static NSString * const kWCRDiscoveredKey = @"WCR.DiscoveredAudioHooks"; // [[class, sel, track], ...]
static NSString * const kWCRProbeKey      = @"WCR.EnableProbe"; // default YES
static NSString * const kWCRPluginVersion = @"0.5.7";

static void WCRShowToast(NSString *text);
static void WCRUpdateIndicator(BOOL on);
static void WCRInstallLifecycle(void);
static void WCRInstallManualAudioHooks(void);
static void WCRAutoScanAudioHooks(void);
static void WCRAggressiveAudioScan(void);
static void WCRInstallProbeAudioHooks(void);
static void WCRDumpAudioCandidates(void);
static void WCRInstallDiscoveredAudioHooks(void);
static void WCRPersistDiscoveredHook(NSString *cls, NSString *sel, NSString *track);
static NSArray *WCRLoadDiscoveredHooks(void);
static BOOL WCRProbeEnabled(void);
static void WCRInstallUIEntries(void);
static void WCREnsureFloatingBall(void);
static void WCRPresentSettingsFrom(UIViewController *from);
static NSInteger WCRLifecycleHookCount(void);
static NSInteger WCRAudioHookCount(void);
static NSString *WCRLastSessionInfo(void);
static void WCRSetLastSessionInfo(NSString *info);

static NSArray<NSArray<NSString *> *> *WCRExtraAudioHooks(void) {
    // Commercial WCallRecorder uses ObjC MSHookMessageEx only (no AudioUnit C APIs).
    // Its PCM selectors are obfuscated; we keep a known-candidate list + runtime discoveries.
    NSMutableArray *hooks = [NSMutableArray array];
    NSArray *known = @[
        // Classic WeChat VoIP sinks (may exist on some 8.0.x builds)
        @[@"VOIPAudioUnitService", @"onMicData:length:", @"mic"],
        @[@"VOIPAudioUnitService", @"onMicData:length:sampleRate:", @"mic"],
        @[@"VOIPAudioUnitService", @"onPlayData:length:", @"remote"],
        @[@"VOIPAudioUnitService", @"onPlayData:length:sampleRate:", @"remote"],
        @[@"AUAudioDevice", @"onMicData:length:", @"mic"],
        @[@"AUAudioDevice", @"onPlayData:length:", @"remote"],
        @[@"AUAudioDevice", @"InputPcmData:len:", @"mic"],
        @[@"AUAudioDevice", @"OutputPcmData:len:", @"remote"],
        @[@"VoIPAudioService", @"onMicData:length:", @"mic"],
        @[@"VoIPAudioService", @"onPlayData:length:", @"remote"],
        @[@"IlinkAudioMgr", @"onMicData:length:", @"mic"],
        @[@"IlinkAudioMgr", @"onPlayData:length:", @"remote"],
        @[@"WCAudioModule", @"onMicData:length:", @"mic"],
        @[@"WCAudioModule", @"onPlayData:length:", @"remote"],
        @[@"MMAudioDataPipe", @"pushMicData:length:", @"mic"],
        @[@"MMAudioDataPipe", @"pushPlayData:length:", @"remote"],
        @[@"WXTalkComponent", @"onMicData:length:", @"mic"],
        @[@"WXTalkComponent", @"onPlayData:length:", @"remote"],
        @[@"VOIPAudioUnitService", @"NotifyOutputOnIndependentThread:length:", @"remote"],
        @[@"VOIPAudioUnitService", @"NotifyInputOnIndependentThread:length:", @"mic"],
        @[@"VOIPAudioUnitService", @"audio_record_callback:length:", @"mic"],
        @[@"VOIPAudioUnitService", @"audio_play_callback:length:", @"remote"],
        @[@"AUAudioDevice", @"NearendPcmReady:len:", @"mic"],
        @[@"AUAudioDevice", @"FarendPcmReady:len:", @"remote"],
        @[@"AUAudioDevice", @"onRecordData:size:", @"mic"],
        @[@"AUAudioDevice", @"onPlaybackData:size:", @"remote"],
        @[@"IlinkAudioMgr", @"onLocalAudioFrame:length:", @"mic"],
        @[@"IlinkAudioMgr", @"onRemoteAudioFrame:length:", @"remote"],
        @[@"IlinkAudioDevice", @"sendAudioData:length:", @"mic"],
        @[@"IlinkAudioDevice", @"recvAudioData:length:", @"remote"],
        @[@"VoIPMPAudioDevice", @"onCapturedData:length:", @"mic"],
        @[@"VoIPMPAudioDevice", @"onRenderData:length:", @"remote"],
        @[@"WCAudioModule", @"deliverRecordedData:length:", @"mic"],
        @[@"WCAudioModule", @"deliverPlaybackData:length:", @"remote"],
        @[@"MMAudioDataPipe", @"pushAudioData:length:", @"mic"],
        @[@"MMAudioDataPipe", @"popAudioData:length:", @"remote"],
    ];
    [hooks addObjectsFromArray:known];
    for (NSArray *item in WCRLoadDiscoveredHooks()) {
        if (item.count >= 3) [hooks addObject:item];
    }
    return hooks;
}

static BOOL WCRProbeEnabled(void) { return WCRBool(kWCRProbeKey, YES); }

static NSArray *WCRLoadDiscoveredHooks(void) {
    id v = [WCRDefaults() objectForKey:kWCRDiscoveredKey];
    if (![v isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in (NSArray *)v) {
        if (![item isKindOfClass:[NSArray class]]) continue;
        NSArray *a = (NSArray *)item;
        if (a.count < 3) continue;
        if (![a[0] isKindOfClass:[NSString class]] || ![a[1] isKindOfClass:[NSString class]] || ![a[2] isKindOfClass:[NSString class]]) continue;
        [out addObject:@[a[0], a[1], a[2]]];
    }
    return out;
}

static void WCRPersistDiscoveredHook(NSString *cls, NSString *sel, NSString *track) {
    if (cls.length == 0 || sel.length == 0 || track.length == 0) return;
    NSMutableArray *all = [WCRLoadDiscoveredHooks() mutableCopy] ?: [NSMutableArray array];
    for (NSArray *it in all) {
        if ([it[0] isEqualToString:cls] && [it[1] isEqualToString:sel] && [it[2] isEqualToString:track]) return;
    }
    [all addObject:@[cls, sel, track]];
    // Cap list
    while (all.count > 64) [all removeObjectAtIndex:0];
    [WCRDefaults() setObject:all forKey:kWCRDiscoveredKey];
    [WCRDefaults() synchronize];
    WCRInfo("persisted audio hook -[%@ %@] track=%@", cls, sel, track);
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
            @"MTVoipMgr", @"VoipCXMgr", @"WCAudioUnit", @"MMAudioDataPipe",
            // Additional Ilink / audio pipeline candidates seen on 8.0.x
            @"IlinkVoIPContext", @"IlinkAudioDevice", @"IlinkVoipMgr",
            @"CloudVoIPAudioMgr", @"VoIPMPAudioMgr", @"AudioSender",
            @"AudioReceiver", @"LivePort", @"ConfDeviceManager",
            @"WXAudioDevice", @"CAudioPlayer", @"CAudioRecorder",
            @"ComponentMgr", @"VOIPComponent", @"VoIPAudioUnitMgr",
            @"AudioDeviceMgr", @"WAAudioPlayer", @"WCAudioPlayer",
            @"AUGraphController", @"TPAudioUnit"
        ];
    });
    return arr;
}

static atomic_int gWCRAudioHooksInstalled = 0;
static atomic_int gWCRLifecycleHooksInstalled = 0;
static atomic_int gWCRLastMicFrames = 0;
static atomic_int gWCRLastRemoteFrames = 0;
static atomic_int gWCRAudioUnitHooksInstalled = 0;
// Probe counters used by status UI (must be declared early).
static atomic_int gWCRProbeHooksInstalled = 0;
static atomic_int gWCRProbeHits = 0;
static NSString *gWCRLastContactHint = nil; // retained manually
static NSString *gWCRLastContactName = nil;
static void WCRSetLastContactHint(NSString *hint);
static NSString *WCRGetLastContactHint(void);
static NSString *WCRGetLastContactName(void);
static BOOL WCRLooksLikeMethodName(NSString *s);
static NSString *WCRResolveActiveCallContact(void);
static NSString *WCRBestSessionName(NSString *reason, NSString *hint);
static void WCRInstallAudioUnitHooks(void);
static void WCRNoteContactFromObject(id obj);
static void WCRInstallAVAudioSessionHooks(void);
static void WCRInstallCallViewControllerHooks(void);
static void WCRRegisterDyldObserver(void);
static void WCRRescanAllHooks(const char *why);
static BOOL WCRCategoryLooksLikeCall(NSString *cat, NSString *mode);
static BOOL WCRIsLikelyInCallUI(void);
static BOOL WCRLooksLikeActiveCallAudio(void);
static void WCRMaybeBeginFromAudioTap(const char *why);
static void WCROnCallMaybeStarted(void);
static void WCRPollCallState(void);
static NSString *WCRScrapeCallUIContactName(void);
static BOOL WCRLooksLikeBadDisplayName(NSString *s);
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

// Commercial plugin uses MSHookMessageEx (CydiaSubstrate). Prefer it when present.
typedef void (*WCRMSHookMessageEx_t)(Class cls, SEL sel, IMP imp, IMP *result);
static WCRMSHookMessageEx_t WCRGetMSHookMessageEx(void) {
    static WCRMSHookMessageEx_t fn = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fn = (WCRMSHookMessageEx_t)dlsym(RTLD_DEFAULT, "MSHookMessageEx");
        if (fn) return;
        const char *libs[] = {
            "/usr/lib/libsubstrate.dylib",
            "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            "/var/jb/usr/lib/libsubstrate.dylib",
            "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
            "/usr/lib/libellekit.dylib",
            "/var/jb/usr/lib/libellekit.dylib",
            NULL
        };
        for (int i = 0; libs[i]; i++) {
            void *h = dlopen(libs[i], RTLD_LAZY);
            if (!h) continue;
            fn = (WCRMSHookMessageEx_t)dlsym(h, "MSHookMessageEx");
            if (fn) break;
        }
    });
    return fn;
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

    // 1) Commercial-style MSHookMessageEx (handles PAC / class clusters better).
    WCRMSHookMessageEx_t hookMsg = WCRGetMSHookMessageEx();
    if (hookMsg) {
        IMP orig = NULL;
        hookMsg(cls, sel, newImp, &orig);
        if (orig) {
            WCRStoreOrig(cls, sel, orig);
            [WCRHookedKeys() addObject:key];
            WCRLog("hooked(MS) -[%s %s]", class_getName(cls), sel_getName(sel));
            return YES;
        }
    }

    // 2) Substrate-free fallback (TrollFools).
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
    if (WCRLooksLikeMethodName(hintOrWxid)) return nil;
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
    // If it already looks like a human-readable remark/nick, keep it.
    if ([hintOrWxid rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location == NSNotFound &&
        hintOrWxid.length <= 32 &&
        ![hintOrWxid containsString:@":"] &&
        ![hintOrWxid containsString:@"null"]) {
        return hintOrWxid;
    }
    return nil;
}

static BOOL WCRLooksLikeMethodName(NSString *s) {
    if (s.length == 0) return YES;
    if ([s containsString:@":"]) return YES;
    // Pure digits / short numeric room ids are not useful display names.
    NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if (s.length <= 12 && [s rangeOfCharacterFromSet:nonDigit].location == NSNotFound) return YES;
    static NSArray<NSString *> *bad;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bad = @[
            @"StartRecord", @"StopRecord", @"StopFor", @"onMultiTalk", @"onEnter", @"onInvite",
            @"openAudio", @"openVideo", @"ilinkOpen", @"createMulti", @"joinMulti", @"manual",
            @"auto-mic", @"auto-remote", @"auto", @"unknown", @"null", @"nil", @"(null)",
            @"Begin", @"End", @"VoIP", @"Ilink", @"MuTalk"
        ];
    });
    for (NSString *b in bad) {
        if ([s rangeOfString:b options:NSCaseInsensitiveSearch].location != NSNotFound) {
            // Allow pure Chinese remarks accidentally matching? only ASCII method-ish
            NSCharacterSet *nonAscii = [[NSCharacterSet characterSetWithRange:NSMakeRange(0, 128)] invertedSet];
            if ([s rangeOfCharacterFromSet:nonAscii].location != NSNotFound) return NO;
            return YES;
        }
    }
    // CamelCase selector-like tokens without spaces
    if ([s rangeOfCharacterFromSet:[NSCharacterSet lowercaseLetterCharacterSet]].location != NSNotFound &&
        [s rangeOfCharacterFromSet:[NSCharacterSet uppercaseLetterCharacterSet]].location != NSNotFound &&
        [s rangeOfString:@" "].location == NSNotFound &&
        s.length > 18) {
        return YES;
    }
    return NO;
}

static BOOL WCRLooksLikeBadDisplayName(NSString *s) {
    if (s.length == 0) return YES;
    if (WCRLooksLikeMethodName(s)) return YES;
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return YES;
    NSCharacterSet *nonDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([t rangeOfCharacterFromSet:nonDigit].location == NSNotFound && t.length <= 16) return YES;
    if ([t.lowercaseString hasPrefix:@"room-"]) {
        NSString *rest = [t substringFromIndex:5];
        if (rest.length && [rest rangeOfCharacterFromSet:nonDigit].location == NSNotFound) return YES;
    }
    NSArray *bad = @[
        @"\u5fae\u4fe1",
        @"WeChat",
        @"\u53d6\u6d88",
        @"\u6302\u65ad",
        @"\u63a5\u542c",
        @"\u514d\u63d0",
        @"\u9759\u97f3",
        @"\u6d6e\u7a97",
        @"\u626b\u58f0\u5668",
        @"\u5207\u6362\u6444\u50cf\u5934",
        @"\u6dfb\u52a0\u6210\u5458",
        @"\u5f55\u97f3\u63d2\u4ef6",
        @"\u901a\u8bdd\u4e2d",
        @"\u7b49\u5f85\u63a5\u542c",
        @"\u6b63\u5728\u901a\u8bdd",
        @"\u89c6\u9891\u901a\u8bdd",
        @"\u8bed\u97f3\u901a\u8bdd",
        @"\u9080\u8bf7\u4f60",
        @"\u7ed3\u675f",
        @"\u62d2\u7edd"
    ];
    for (NSString *b in bad) {
        if ([t isEqualToString:b]) return YES;
        if ([t containsString:b] && t.length <= b.length + 2) return YES;
    }
    return NO;
}

static void WCRSetLastContactHint(NSString *hint) {
    if (hint.length == 0 || WCRLooksLikeMethodName(hint)) return;
    NSString *copy = [hint copy];
    NSString *resolved = WCRResolveRemarkName(copy) ?: copy;
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        gWCRLastContactHint = copy;
        if (resolved.length && !WCRLooksLikeBadDisplayName(resolved)) {
            gWCRLastContactName = [resolved copy];
        } else if (!WCRLooksLikeBadDisplayName(copy)) {
            gWCRLastContactName = copy;
        }
    }
}

static NSString *WCRGetLastContactHint(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    @synchronized (lock) { return gWCRLastContactHint; }
}
static NSString *WCRGetLastContactName(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ lock = [NSObject new]; });
    @synchronized (lock) { return gWCRLastContactName; }
}

static void WCRNoteContactFromObject(id obj) {
    if (!obj) return;
    if ([obj isKindOfClass:[NSString class]]) {
        WCRSetLastContactHint((NSString *)obj);
        return;
    }
    NSString *name = WCRContactDisplayNameFromContact(obj);
    if (name.length) { WCRSetLastContactHint(name); return; }
    NSString *hint = nil;
    // Fall through uses later helper; keep local extract here for early use.
    hint = WCRPropString(obj, @[@"m_nsUsrName", @"userName", @"username", @"m_nsNickName", @"m_nsRemark", @"m_nsRemarkName"]);
    if (hint.length) WCRSetLastContactHint(hint);
}

static id WCRFirstService(NSArray<NSString *> *names) {
    for (NSString *n in names) {
        id s = WCRServiceOfClass(n);
        if (s) return s;
    }
    // try singleton-style
    for (NSString *n in names) {
        Class cls = NSClassFromString(n);
        if (!cls) continue;
        for (NSString *selName in @[@"sharedInstance", @"shared", @"sharedMgr", @"sharedManager", @"Instance", @"instance"]) {
            @try {
                SEL sel = NSSelectorFromString(selName);
                if (![cls respondsToSelector:sel]) continue;
                id obj = ((id(*)(id, SEL))objc_msgSend)(cls, sel);
                if (obj) return obj;
            } @catch (__unused NSException *e) {}
        }
    }
    return nil;
}

static NSString *WCRResolveActiveCallContact(void) {
    NSString *cached = WCRGetLastContactName() ?: WCRGetLastContactHint();
    if (cached.length && !WCRLooksLikeMethodName(cached)) {
        NSString *r = WCRResolveRemarkName(cached);
        if (r.length && !WCRLooksLikeMethodName(r)) return r;
        if (!WCRLooksLikeMethodName(cached)) return cached;
    }

    NSArray *mgrNames = @[
        @"VOIPMgr", @"VoIPMgr", @"VOIPComponentMgr", @"IlinkVoIPMgr", @"MMIlinkService",
        @"IlinkService", @"CloudVoIPMgr", @"MultiTalkMgr", @"VoIPUIManager", @"VoipCXMgr",
        @"VOIPCSMgr", @"VoIPInvitationService", @"WCCallKitManager", @"VoipUIManager",
        @"VoIPMainViewController", @"IlinkVoIPContext", @"MTVoipMgr"
    ];
    NSArray *propNames = @[
        @"m_currentContact", @"currentContact", @"m_contact", @"contact", @"remoteContact",
        @"m_toContact", @"toContact", @"fromContact", @"m_fromContact", @"callerContact",
        @"calleeContact", @"inviteContact", @"m_inviteContact", @"talkContact",
        @"m_nsToUsr", @"m_nsFromUsr", @"m_nsUsername", @"username", @"userName",
        @"m_nsRemoteUserName", @"remoteUserName", @"otherContact"
    ];
    for (NSString *mn in mgrNames) {
        id mgr = WCRFirstService(@[mn]);
        if (!mgr) continue;
        for (NSString *pn in propNames) {
            @try {
                SEL sel = NSSelectorFromString(pn);
                if (![mgr respondsToSelector:sel]) continue;
                id v = ((id(*)(id, SEL))objc_msgSend)(mgr, sel);
                if (!v) continue;
                if ([v isKindOfClass:[NSString class]]) {
                    NSString *r = WCRResolveRemarkName((NSString *)v);
                    if (r.length && !WCRLooksLikeMethodName(r)) { WCRSetLastContactHint((NSString *)v); return r; }
                    if (!WCRLooksLikeMethodName((NSString *)v)) { WCRSetLastContactHint((NSString *)v); return (NSString *)v; }
                } else {
                    NSString *name = WCRContactDisplayNameFromContact(v);
                    if (name.length && !WCRLooksLikeMethodName(name)) { WCRSetLastContactHint(name); return name; }
                    NSString *usr = WCRPropString(v, @[@"m_nsUsrName", @"userName", @"username"]);
                    if (usr.length) {
                        NSString *r = WCRResolveRemarkName(usr);
                        if (r.length && !WCRLooksLikeMethodName(r)) { WCRSetLastContactHint(usr); return r; }
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    }

    // MultiTalk group title fallback
    id mt = WCRFirstService(@[@"MultiTalkMgr"]);
    if (mt) {
        @try {
            SEL sel = NSSelectorFromString(@"getCurrentTalkingGroupId");
            if ([mt respondsToSelector:sel]) {
                id gid = ((id(*)(id, SEL))objc_msgSend)(mt, sel);
                NSString *s = WCRSafeDesc(gid);
                if (s.length && !WCRLooksLikeMethodName(s)) return s;
            }
        } @catch (__unused NSException *e) {}
    }
    NSString *uiName = WCRScrapeCallUIContactName();
    if (uiName.length && !WCRLooksLikeBadDisplayName(uiName)) {
        WCRSetLastContactHint(uiName);
        return uiName;
    }
    return nil;
}

static NSString *WCRBestSessionName(NSString *reason, NSString *hint) {
    NSString *active = WCRResolveActiveCallContact();
    if (active.length && !WCRLooksLikeBadDisplayName(active)) return active;

    NSString *cached = WCRGetLastContactName();
    if (cached.length && !WCRLooksLikeBadDisplayName(cached)) return cached;

    if (hint.length && !WCRLooksLikeBadDisplayName(hint)) {
        NSString *r = WCRResolveRemarkName(hint);
        if (r.length && !WCRLooksLikeBadDisplayName(r)) return r;
        if (!WCRLooksLikeBadDisplayName(hint)) return hint;
    }

    NSString *rawHint = WCRGetLastContactHint();
    if (rawHint.length && !WCRLooksLikeBadDisplayName(rawHint)) {
        NSString *r = WCRResolveRemarkName(rawHint);
        if (r.length && !WCRLooksLikeBadDisplayName(r)) return r;
        return rawHint;
    }

    NSString *uiName = WCRScrapeCallUIContactName();
    if (uiName.length && !WCRLooksLikeBadDisplayName(uiName)) return uiName;

    if (reason.length && !WCRLooksLikeMethodName(reason) && !WCRLooksLikeBadDisplayName(reason)) return reason;
    return @"\u901a\u8bdd";
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
static BOOL WCRKeyLooksLifecycle(NSString *low) {
    if (low.length == 0) return NO;
    return ([low containsString:@"startrecord"] || [low containsString:@"stopforvoip"] ||
            [low containsString:@"stoprecord"] || [low containsString:@"hangup"] ||
            [low containsString:@"endcall"] || [low containsString:@"cancelcall"] ||
            [low containsString:@"onenter"] || [low containsString:@"oninvite"] ||
            [low containsString:@"openaudio"] || [low containsString:@"openvideo"] ||
            [low containsString:@"ilinkopen"] || [low containsString:@"createmulti"] ||
            [low containsString:@"joinmulti"] || [low containsString:@"onaccept"] ||
            [low containsString:@"onmultitalk"] || [low containsString:@"stopfor"] ||
            [low containsString:@"closewindow"] || [low containsString:@"setcategory"] ||
            [low containsString:@"setactive"] || [low containsString:@"avaudiosession"] ||
            [low containsString:@"voipview"] || [low containsString:@"onvoipcall"] ||
            [low containsString:@"oncallend"] || [low containsString:@"rejectcall"] ||
            [low containsString:@"hangupcall"] || [low containsString:@"dismissvoip"]);
}
static BOOL WCRKeyLooksAudio(NSString *low) {
    if (low.length == 0) return NO;
    if (WCRKeyLooksLifecycle(low)) return NO;
    if ([low containsString:@"viewdidappear"] || [low containsString:@"newsetting"]) return NO;
    return ([low containsString:@"pcm"] || [low containsString:@"audio"] ||
            [low containsString:@"mic"] || [low containsString:@"play"] ||
            [low containsString:@"buffer"] || [low containsString:@"frame"] ||
            [low containsString:@"record"] || [low containsString:@"speaker"] ||
            [low containsString:@"remote"] || [low containsString:@"local"] ||
            [low containsString:@"audiounit"] || [low containsString:@"render"]);
}
static NSInteger WCRLifecycleHookCount(void) {
    NSInteger n = 0;
    for (NSString *key in WCRHookedKeys()) {
        if (WCRKeyLooksLifecycle(key.lowercaseString)) n++;
    }
    if (n == 0) n = (NSInteger)atomic_load(&gWCRLifecycleHooksInstalled);
    return n;
}
static NSInteger WCRAudioHookCount(void) {
    NSInteger n = 0;
    for (NSString *key in WCRHookedKeys()) {
        if (WCRKeyLooksAudio(key.lowercaseString)) n++;
    }
    if (atomic_load(&gWCRAudioUnitHooksInstalled)) n += 1; // C-level AU capture counts as one
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
    // Prefer remark/display name for the root MP3 copy; keep timestamp suffix if present.
    NSString *base = displayName.length ? displayName : sessionDir.lastPathComponent;
    if (WCRLooksLikeMethodName(base)) base = sessionDir.lastPathComponent;
    NSString *ts = nil;
    NSString *sid = sessionDir.lastPathComponent ?: @"";
    NSRange r = [sid rangeOfString:@"_" options:NSBackwardsSearch];
    if (r.location != NSNotFound && r.location + 1 < sid.length) {
        NSString *maybe = [sid substringFromIndex:r.location + 1];
        // yyyyMMdd_HHmmss ends up as two tokens; keep last 15 chars pattern if looks like time.
        if (maybe.length == 6 || maybe.length == 15 || maybe.length == 8) ts = maybe;
        // Better: if sid contains yyyyMMdd_HHmmss take that suffix.
        if (sid.length >= 15) {
            NSString *tail = [sid substringFromIndex:sid.length - 15];
            if (tail.length == 15 && [tail characterAtIndex:8] == '_') ts = tail;
        }
    }
    NSString *safe = WCRSanitizeName(ts.length ? [NSString stringWithFormat:@"%@_%@", base, ts] : base);
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


static BOOL WCRClassNameLooksCallUI(const char *cn) {
    if (!cn) return NO;
    // WeChat 8.0.x uses mixed VoIP/Ilink/MultiTalk/Mono naming.
    return WCRCaseContains(cn, "voip") || WCRCaseContains(cn, "ilink") ||
           WCRCaseContains(cn, "multitalk") || WCRCaseContains(cn, "mtalk") ||
           WCRCaseContains(cn, "callkit") || WCRCaseContains(cn, "confroom") ||
           WCRCaseContains(cn, "voicecall") || WCRCaseContains(cn, "videocall") ||
           WCRCaseContains(cn, "wxvoip") || WCRCaseContains(cn, "mpvoip") ||
           WCRCaseContains(cn, "voiceroom") || WCRCaseContains(cn, "calling") ||
           WCRCaseContains(cn, "videovoip") || WCRCaseContains(cn, "mono") ||
           WCRCaseContains(cn, "wccall") || WCRCaseContains(cn, "inviteview") ||
           (WCRCaseContains(cn, "receiver") && WCRCaseContains(cn, "view")) ||
           (WCRCaseContains(cn, "caller") && WCRCaseContains(cn, "view")) ||
           // cautious: "*Talk*" classes used by MultiTalk, but avoid pure UITableView etc.
           (WCRCaseContains(cn, "talk") && (WCRCaseContains(cn, "multi") || WCRCaseContains(cn, "voip") ||
                                            WCRCaseContains(cn, "mono") || WCRCaseContains(cn, "room") ||
                                            WCRCaseContains(cn, "component") || WCRCaseContains(cn, "window") ||
                                            WCRCaseContains(cn, "view") || WCRCaseContains(cn, "main") ||
                                            WCRCaseContains(cn, "mgr") || WCRCaseContains(cn, "ui")));
}

static BOOL WCRViewTreeHasCallUI(UIView *view, int depth) {
    if (!view || depth > 10) return NO;
    const char *cn = class_getName(object_getClass(view));
    if (WCRClassNameLooksCallUI(cn)) return YES;
    for (UIView *sub in view.subviews) {
        if (WCRViewTreeHasCallUI(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL WCRLabelLooksLikeCallChrome(NSString *t) {
    if (t.length == 0 || t.length > 16) return NO;
    NSString *s = t.lowercaseString ?: @"";
    // Strong call-screen chrome only (avoid generic cancel/add).
    if ([t containsString:@"\u6302\u65ad"] || [t containsString:@"\u63a5\u542c"] || [t containsString:@"\u9759\u97f3"] ||
        [t containsString:@"\u514d\u63d0"] || [t containsString:@"\u626c\u58f0\u5668"] || [t containsString:@"\u5207\u5230\u8bed\u97f3"] ||
        [t containsString:@"\u9080\u8bf7\u52a0\u5165"] || [t containsString:@"\u7b49\u5f85\u63a5\u542c"] || [t containsString:@"\u6b63\u5728\u901a\u8bdd"] ||
        [s containsString:@"speaker"] || [s containsString:@"mute"] || [s isEqualToString:@"end"] ||
        [s containsString:@"end call"] || [s containsString:@"accept"] || [s containsString:@"decline"]) {
        return YES;
    }
    return NO;
}

static BOOL WCRViewTreeHasCallChrome(UIView *view, int depth) {
    if (!view || depth > 8) return NO;
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            if (WCRLabelLooksLikeCallChrome(((UILabel *)view).text)) return YES;
        } else if ([view isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)view;
            if (WCRLabelLooksLikeCallChrome(b.currentTitle)) return YES;
            if (WCRLabelLooksLikeCallChrome(b.accessibilityLabel)) return YES;
        } else {
            if (WCRLabelLooksLikeCallChrome(view.accessibilityLabel)) return YES;
        }
        for (UIView *sub in view.subviews) {
            if (WCRViewTreeHasCallChrome(sub, depth + 1)) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

static BOOL WCRWalkVCLooksCallUI(UIViewController *vc, int depth) {
    if (!vc || depth > 10) return NO;
    @try {
        const char *cn = class_getName(object_getClass(vc));
        if (WCRClassNameLooksCallUI(cn)) return YES;
        if (vc.isViewLoaded && WCRViewTreeHasCallUI(vc.view, 0)) return YES;
        if (vc.isViewLoaded && WCRViewTreeHasCallChrome(vc.view, 0)) return YES;
        if (vc.presentedViewController && WCRWalkVCLooksCallUI(vc.presentedViewController, depth + 1)) return YES;
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)vc;
            if (WCRWalkVCLooksCallUI(nav.visibleViewController, depth + 1)) return YES;
            for (UIViewController *c in nav.viewControllers) {
                if (WCRWalkVCLooksCallUI(c, depth + 1)) return YES;
            }
        }
        if ([vc isKindOfClass:[UITabBarController class]]) {
            UITabBarController *tab = (UITabBarController *)vc;
            if (WCRWalkVCLooksCallUI(tab.selectedViewController, depth + 1)) return YES;
        }
        for (UIViewController *c in vc.childViewControllers) {
            if (WCRWalkVCLooksCallUI(c, depth + 1)) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

// Commercial plugin ends on StopForVoIP; free rewrite also watches call UI disappearance.
static BOOL WCRIsLikelyInCallUI(void) {
    @try {
        // Proximity often turns on during earpiece voice call.
        @try {
            if (UIDevice.currentDevice.proximityMonitoringEnabled && UIDevice.currentDevice.proximityState) {
                return YES;
            }
        } @catch (__unused NSException *e) {}

        NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
        UIWindow *key = WCRKeyWindow();
        if (key) [windows addObject:key];
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w && !w.hidden && w.alpha > 0.01 && ![windows containsObject:w]) [windows addObject:w];
                }
            }
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w && !w.hidden && ![windows containsObject:w]) [windows addObject:w];
        }
#pragma clang diagnostic pop

        for (UIWindow *win in windows) {
            if (WCRViewTreeHasCallUI(win, 0)) return YES;
            if (WCRViewTreeHasCallChrome(win, 0)) return YES;
            const char *wcn = class_getName(object_getClass(win));
            if (WCRClassNameLooksCallUI(wcn)) return YES;
            if (WCRWalkVCLooksCallUI(win.rootViewController, 0)) return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}


static void WCRCollectLabels(UIView *view, NSMutableArray<NSString *> *out, int depth) {
    if (!view || depth > 10 || out.count > 40) return;
    @try {
        if ([view isKindOfClass:[UILabel class]]) {
            NSString *t = [((UILabel *)view).text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length >= 1 && t.length <= 24 && !WCRLooksLikeBadDisplayName(t)) {
                [out addObject:t];
            }
        } else if ([view isKindOfClass:[UIButton class]]) {
            NSString *t = [((UIButton *)view).currentTitle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length >= 1 && t.length <= 24 && !WCRLooksLikeBadDisplayName(t)) {
                [out addObject:t];
            }
        }
        for (UIView *sub in view.subviews) WCRCollectLabels(sub, out, depth + 1);
    } @catch (__unused NSException *e) {}
}

static NSString *WCRScrapeCallUIContactName(void) {
    @try {
        UIWindow *key = WCRKeyWindow();
        if (!key) return nil;
        NSMutableArray<NSString *> *labels = [NSMutableArray array];
        WCRCollectLabels(key, labels, 0);
        for (NSString *t in labels) {
            if (WCRLooksLikeBadDisplayName(t)) continue;
            BOOL hasCJK = NO;
            for (NSUInteger i = 0; i < t.length; i++) {
                if ([t characterAtIndex:i] > 0x2E80) { hasCJK = YES; break; }
            }
            if (hasCJK) return t;
        }
        for (NSString *t in labels) {
            if (!WCRLooksLikeBadDisplayName(t)) return t;
        }
    } @catch (__unused NSException *e) {}
    return nil;
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
        // Commercial model: keep hunting ObjC lifecycle + PCM sinks while call is active.
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                WCRRescanAllHooks("idle-watchdog");
            } @catch (__unused NSException *e) {}
        });
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        // Late remark resolve while recording.
        if (!self.contactDisplayName.length || WCRLooksLikeBadDisplayName(self.contactDisplayName)) {
            NSString *better = WCRBestSessionName(@"live", WCRGetLastContactHint());
            if (better.length && !WCRLooksLikeBadDisplayName(better)) {
                self.contactDisplayName = better;
                if (self.meta) self.meta[@"displayName"] = better;
            }
        }
        __block BOOL inCallUI = YES;
        dispatch_sync(dispatch_get_main_queue(), ^{
            inCallUI = WCRIsLikelyInCallUI();
        });
        if (!inCallUI) {
            NSTimeInterval quietFor = (self.lastPCMAt > 0) ? (now - self.lastPCMAt) : 99.0;
            if (!self.everHadPCM || quietFor > 2.0) {
                WCRInfo("idle watchdog: call-ui-gone quiet=%.1fs everPCM=%d", quietFor, self.everHadPCM);
                [self endWithReason:@"call-ui-gone"];
                return;
            }
        }
        if (!self.everHadPCM) {
            NSTimeInterval age = now - self.lastPCMAt;
            if (!inCallUI && age > 1.0) {
                WCRInfo("idle watchdog: no-pcm-after-hangup");
                [self endWithReason:@"no-pcm-after-hangup"];
                return;
            }
            if (age > 20.0) {
                WCRInfo("idle watchdog: no-pcm-timeout");
                [self endWithReason:@"no-pcm-timeout"];
            }
            return;
        }
        NSTimeInterval ref = MAX(self.lastVoiceAt, self.lastPCMAt);
        if (ref > 0 && (now - ref) > 4.0) {
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
    if (hint.length) WCRSetLastContactHint(hint);
    NSString *resolved = WCRBestSessionName(reason, hint);
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
            WCRInstallAVAudioSessionHooks();
            WCRInstallCallViewControllerHooks();
            WCRInstallDiscoveredAudioHooks();
            WCRInstallManualAudioHooks();
            WCRAutoScanAudioHooks();
            WCRInstallAudioUnitHooks();
            // During an active call: commercial-style ObjC sink hunt + AU fallback.
            WCRAggressiveAudioScan();
            WCRInstallProbeAudioHooks();
            static dispatch_once_t onceDump;
            dispatch_once(&onceDump, ^{ WCRDumpAudioCandidates(); });
        } @catch (__unused NSException *e) {}
        if (!WCRBool(kWCRPrivateKey, NO)) WCRShowToast([NSString stringWithFormat:@"通话录音已开始\n%@", sid]);
        WCRUpdateIndicator(YES);
        WCREnsureFloatingBall();
    });
}
- (void)beginWithReason:(NSString *)reason contactHint:(NSString *)hint sampleRate:(double)sr {
    // On ioQueue: inline. On main/UI/poller: sync so isRecording is visible immediately.
    // On any other (likely audio RT) queue: async to avoid glitch/priority inversion.
    if (strcmp(dispatch_queue_get_label(DISPATCH_CURRENT_QUEUE_LABEL), "com.blueskycrb.wcallrecorder.io") == 0) {
        [self beginInlineOnIOQueueWithReason:reason contactHint:hint sampleRate:sr];
        return;
    }
    if ([NSThread isMainThread]) {
        dispatch_sync(self.ioQueue, ^{
            [self beginInlineOnIOQueueWithReason:reason contactHint:hint sampleRate:sr];
        });
        return;
    }
    dispatch_async(self.ioQueue, ^{
        [self beginInlineOnIOQueueWithReason:reason contactHint:hint sampleRate:sr];
    });
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
        // Late contact resolve (Ilink sometimes only has contact after connected).
        // Commercial plugin uses m_nsRemark / m_nsNickName for display naming.
        NSString *better = WCRBestSessionName(reason, self.contactDisplayName);
        BOOL weakName = (self.contactDisplayName.length == 0 ||
                         WCRLooksLikeMethodName(self.contactDisplayName) ||
                         [self.contactDisplayName hasPrefix:@"通话_"] ||
                         [self.contactDisplayName isEqualToString:@"unknown"] ||
                         [self.contactDisplayName isEqualToString:@"auto"] ||
                         [self.contactDisplayName isEqualToString:@"manual"]);
        if (better.length && !WCRLooksLikeMethodName(better) &&
            (weakName || ![better isEqualToString:self.contactDisplayName])) {
            self.contactDisplayName = better;
            self.meta[@"displayName"] = better;
            WCRInfo("resolved better displayName=%@", better);
        }
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

        // Rename session folder to remark-based name (commercial-style display naming).
        if (self.contactDisplayName.length && self.sessionDir.length && self.sessionID.length) {
            NSString *safe = WCRSanitizeName(self.contactDisplayName);
            if (safe.length && ![self.sessionID hasPrefix:safe]) {
                NSString *ts = nil;
                if (self.sessionID.length >= 15) {
                    NSString *tail = [self.sessionID substringFromIndex:self.sessionID.length - 15];
                    if (tail.length == 15 && [tail characterAtIndex:8] == '_') ts = tail;
                }
                NSString *newSid = ts.length ? [NSString stringWithFormat:@"%@_%@", safe, ts] : safe;
                NSString *newDir = [[self rootDir] stringByAppendingPathComponent:newSid];
                if (![newDir isEqualToString:self.sessionDir] &&
                    ![[NSFileManager defaultManager] fileExistsAtPath:newDir]) {
                    NSError *renErr = nil;
                    if ([[NSFileManager defaultManager] moveItemAtPath:self.sessionDir toPath:newDir error:&renErr]) {
                        WCRInfo("renamed session %@ -> %@", self.sessionID, newSid);
                        self.sessionDir = newDir;
                        self.sessionID = newSid;
                        self.meta[@"id"] = newSid;
                        self.meta[@"displayName"] = self.contactDisplayName;
                        if (mp3Path.length && [mp3Path hasSuffix:@"/call.mp3"]) {
                            mp3Path = [newDir stringByAppendingPathComponent:@"call.mp3"];
                        }
                        if (mp3OK) {
                            NSString *fresh = nil;
                            if (WCRExportSessionMP3(newDir, self.contactDisplayName, self.sampleRate, &fresh) && fresh.length) {
                                mp3Path = fresh;
                            }
                        }
                    } else {
                        WCRInfo("session rename failed: %@", renErr);
                    }
                }
            }
        }

        self.meta[@"endedAt"] = @([NSDate date].timeIntervalSince1970);
        self.meta[@"endReason"] = reason ?: @"";
        self.meta[@"micBytes"] = @(self.micBytes);
        self.meta[@"remoteBytes"] = @(self.remoteBytes);
        self.meta[@"mixed"] = @(mixedOK);
        self.meta[@"mp3"] = @(mp3OK);
        if (self.contactDisplayName.length) self.meta[@"displayName"] = self.contactDisplayName;
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
                    WCRShowToast([NSString stringWithFormat:@"\u901a\u8bdd\u5f55\u97f3\u5df2\u7ed3\u675f(\u65e0\u97f3\u9891)\n%@\n\u6253\u5f00\u60ac\u6d6e\u7403\u67e5\u770b\u8bca\u65ad", dir.lastPathComponent]);
                } else if (mp3OK) {
                    WCRShowToast([NSString stringWithFormat:@"\u901a\u8bdd\u5f55\u97f3\u5df2\u4fdd\u5b58(MP3)\n%@", mp3Show]);
                } else {
                    WCRShowToast([NSString stringWithFormat:@"\u901a\u8bdd\u5f55\u97f3\u5df2\u4fdd\u5b58\n%@", dir.lastPathComponent]);
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
    // Explicit empty session marker
    if ([meta isKindOfClass:[NSDictionary class]]) {
        unsigned long long micB = [meta[@"micBytes"] unsignedLongLongValue];
        unsigned long long remoteB = [meta[@"remoteBytes"] unsignedLongLongValue];
        BOOL mp3Flag = [meta[@"mp3"] boolValue];
        if (!mp3Flag && micB == 0 && remoteB == 0) return nil;
    }
    NSString *mp3Meta = [meta isKindOfClass:[NSDictionary class]] ? meta[@"mp3Path"] : nil;
    if ([mp3Meta isKindOfClass:[NSString class]] && [fm fileExistsAtPath:mp3Meta]) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:mp3Meta error:nil];
        if ([attrs fileSize] > 1024) return mp3Meta;
    }
    NSArray *cands = @[
        [dir stringByAppendingPathComponent:@"call.mp3"],
        [dir stringByAppendingPathComponent:@"mixed.wav"],
        [dir stringByAppendingPathComponent:@"remote.wav"],
        [dir stringByAppendingPathComponent:@"mic.wav"],
    ];
    for (NSString *p in cands) {
        if (![fm fileExistsAtPath:p]) continue;
        NSDictionary *attrs = [fm attributesOfItemAtPath:p error:nil];
        unsigned long long sz = [attrs fileSize];
        // WAV header alone is 44 bytes; require real PCM payload.
        if ([p.pathExtension.lowercaseString isEqualToString:@"wav"]) {
            if (sz > 44 + 1024) return p;
        } else if ([p.pathExtension.lowercaseString isEqualToString:@"mp3"]) {
            if (sz > 256) return p;
        } else if (sz > 1024) {
            return p;
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
        return @"若通话结束仍无音频：看 AU 是否为1。AU=0 表示 C 钩未装上；AU=1 仍 mic=0 则需 Frida 补 ObjC PCM 选择子。";
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
            cell.detailTextLabel.text = [NSString stringWithFormat:@"音频钩子约: %ld  AU=%d%@  probe=%d/%d  发现=%lu  (总hook=%lu)",
                                        (long)WCRAudioHookCount(),
                                        (int)atomic_load(&gWCRAudioUnitHooksInstalled),
                                        atomic_load(&gWCRAudioUnitHooksInstalled) ? @" fishhook/MS" : @" 未装",
                                        (int)atomic_load(&gWCRProbeHooksInstalled),
                                        (int)atomic_load(&gWCRProbeHits),
                                        (unsigned long)WCRLoadDiscoveredHooks().count,
                                        (unsigned long)WCRHookedKeys().count];
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
    NSString *playable = item[@"playPath"] ?: @"";
    if (playable.length == 0) {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"无有效音频 · mic=%@ remote=%@ · %@",
                                     meta[@"micBytes"] ?: @"?",
                                     meta[@"remoteBytes"] ?: @"?",
                                     meta[@"endReason"] ?: (meta[@"reason"] ?: @"-")];
    } else {
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · mic=%@ remote=%@ · %@",
                                     fmt,
                                     meta[@"micBytes"] ?: @"?",
                                     meta[@"remoteBytes"] ?: @"?",
                                     meta[@"endReason"] ?: (meta[@"reason"] ?: @"-")];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            WCRRescanAllHooks("manual");
            WCRShowToast([NSString stringWithFormat:@"\u5df2\u626b\u63cf\n\u751f\u547d\u5468\u671f=%ld \u97f3\u9891\u7ea6=%ld AU=%d",
                          (long)WCRLifecycleHookCount(), (long)WCRAudioHookCount(),
                          (int)atomic_load(&gWCRAudioUnitHooksInstalled)]);
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
            WCRShowToast(@"\u8def\u5f84\u5df2\u590d\u5236");
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
        WCRShowToast(@"没有可播放文件（可能本次通话未采到音频）");
        return;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    unsigned long long sz = [attrs fileSize];
    BOOL isWav = [path.pathExtension.lowercaseString isEqualToString:@"wav"];
    BOOL isMp3 = [path.pathExtension.lowercaseString isEqualToString:@"mp3"];
    if ((isWav && sz <= 44 + 1024) || (isMp3 && sz <= 256) || (!isWav && !isMp3 && sz <= 1024)) {
        WCRShowToast(@"录音无有效音频\nPCM 未命中或通话过短");
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
        WCRShowToast([NSString stringWithFormat:@"播放失败\n%@\n若是空录音请先确认 PCM>0", err.localizedDescription ?: @"unknown"]);
        return;
    }
    player.delegate = self;
    player.volume = 1.0;
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
    NSString *msg = playPath.length ? playPath.lastPathComponent : @"无有效音频（PCM未采到，无法播放）";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:msg
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
        UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"\u5f55\u97f3"
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

static void (*WCR_orig_vc_viewDidAppear)(id, SEL, BOOL) = NULL;
static void WCR_repl_vc_viewDidAppear(id self, SEL cmd, BOOL animated) {
    // Prefer per-class original (multi-class hooks). Global UIViewController orig is fallback only.
    IMP o = WCRLookupOrig(self, cmd);
    if (o) ((void(*)(id,SEL,BOOL))o)(self, cmd, animated);
    else if (WCR_orig_vc_viewDidAppear) WCR_orig_vc_viewDidAppear(self, cmd, animated);
    if (!WCREnabled()) return;
    @try {
        const char *cn = class_getName(object_getClass(self));
        if (!WCRClassNameLooksCallUI(cn)) return;
        // Answering/incoming call screens: force open session + rescan hooks.
        WCRInfo("call VC appear: %s", cn ?: "?");
        WCROnCallMaybeStarted();
        NSString *hint = WCRGetLastContactName() ?: WCRGetLastContactHint() ?: WCRScrapeCallUIContactName();
        if (hint.length == 0 || WCRLooksLikeBadDisplayName(hint)) hint = @"\u901a\u8bdd";
        [[WCRSessionManager shared] beginWithReason:[NSString stringWithFormat:@"vc-appear-%s", cn ?: "call"]
                                       contactHint:hint
                                        sampleRate:WCRPreferredSampleRate()];
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
        // Global call-screen detector: answering an incoming call always presents a VoIP VC.
        Class vcCls = NSClassFromString(@"UIViewController");
        if (vcCls) {
            SEL appear = @selector(viewDidAppear:);
            Method m = class_getInstanceMethod(vcCls, appear);
            if (m) {
                WCR_orig_vc_viewDidAppear = (void (*)(id, SEL, BOOL))method_getImplementation(m);
                if (WCRHookInstance(vcCls, appear, (IMP)WCR_repl_vc_viewDidAppear)) {
                    WCRInfo("hooked UIViewController viewDidAppear for call-screen detect");
                } else if (WCROrigMap()[WCRHookKey(vcCls, appear)]) {
                    NSValue *v = WCROrigMap()[WCRHookKey(vcCls, appear)];
                    if (v) WCR_orig_vc_viewDidAppear = (void (*)(id, SEL, BOOL))v.pointerValue;
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
    if (now - last < 0.8) return;
    last = now;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            WCRRescanAllHooks("call-start");
            WCRAggressiveAudioScan();
            WCRDumpAudioCandidates();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    WCRRescanAllHooks("call-start+0.8");
                    WCRAggressiveAudioScan();
                } @catch (__unused NSException *e) {}
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    WCRRescanAllHooks("call-start+2.5");
                    WCRAggressiveAudioScan();
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
            [[WCRSessionManager shared] beginWithReason:reason contactHint:WCRGetLastContactHint() sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd);
}

static void wcr_call_id(id self, SEL cmd, id arg) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    @try {
        WCRNoteContactFromObject(arg);
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
            NSString *hint = WCRContactHintFromObject(arg);
            if (hint.length == 0 || WCRLooksLikeMethodName(hint)) hint = WCRGetLastContactHint();
            [[WCRSessionManager shared] beginWithReason:reason contactHint:hint sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd, arg);
}

static void wcr_call_id_id(id self, SEL cmd, id a, id b) {
    void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))WCRLookupOrig(self, cmd);
    @try {
        WCRNoteContactFromObject(a);
        WCRNoteContactFromObject(b);
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle";
            NSString *hint = WCRContactHintFromObject(a) ?: WCRContactHintFromObject(b) ?: WCRGetLastContactHint();
            if (hint.length && WCRLooksLikeMethodName(hint)) hint = WCRGetLastContactHint();
            [[WCRSessionManager shared] beginWithReason:reason contactHint:hint sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd, a, b);
}

// Ilink window open carries the real contact (commercial dylib also hooks this).
static void wcr_ilink_open(id self, SEL cmd, id contact, id msgWrap, BOOL isCaller, id from, BOOL startInApp, BOOL isEarMode, BOOL isAudioMode) {
    void (*orig)(id, SEL, id, id, BOOL, id, BOOL, BOOL, BOOL) =
        (void (*)(id, SEL, id, id, BOOL, id, BOOL, BOOL, BOOL))WCRLookupOrig(self, cmd);
    @try {
        WCRNoteContactFromObject(contact);
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *hint = WCRContactHintFromObject(contact) ?: WCRContactDisplayNameFromContact(contact) ?: WCRGetLastContactHint();
            [[WCRSessionManager shared] beginWithReason:@"ilinkOpenWindow" contactHint:hint sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    if (orig) orig(self, cmd, contact, msgWrap, isCaller, from, startInApp, isEarMode, isAudioMode);
}

static void wcr_call_room(id self, SEL cmd, id roomID, id roomKey) {
    void (*orig)(id, SEL, id, id) = (void (*)(id, SEL, id, id))WCRLookupOrig(self, cmd);
    @try {
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *hint = WCRGetLastContactName() ?: WCRGetLastContactHint() ?: WCRScrapeCallUIContactName();
            if (hint.length == 0 || WCRLooksLikeBadDisplayName(hint)) hint = @"\u901a\u8bdd";
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

    const void *bytes = p;
    NSUInteger byteLen = (NSUInteger)n;
    // Heuristic: sample-count (not bytes) for common VoIP frames.
    if (n < 4096 && (n == 160 || n == 320 || n == 480 || n == 640 || n == 960 || n == 1280 || n == 1920)) {
        const float *f32 = (const float *)p;
        BOOL looksFloat = NO;
        if (n >= 4) {
            float a = f32[0], b = f32[1];
            if (a > -1.5f && a < 1.5f && b > -1.5f && b < 1.5f && (a != 0.f || b != 0.f)) looksFloat = YES;
        }
        if (looksFloat) {
            NSMutableData *pcm = [NSMutableData dataWithLength:(NSUInteger)n * 2];
            int16_t *dst = (int16_t *)pcm.mutableBytes;
            for (NSInteger i = 0; i < n; i++) {
                float v = f32[i];
                if (v > 1.f) v = 1.f; if (v < -1.f) v = -1.f;
                dst[i] = (int16_t)(v * 32767.f);
            }
            if (track == WCRTrackMic) [[WCRSessionManager shared] appendMic:pcm.bytes length:pcm.length sampleRate:sr];
            else [[WCRSessionManager shared] appendRemote:pcm.bytes length:pcm.length sampleRate:sr];
            WCRLog("pcm %s %s nSamples=%ld (f32) sr=%.0f", track == WCRTrackMic ? "mic" : "remote", sel_getName(cmd), (long)n, sr);
            (void)self;
            return;
        }
        byteLen = (NSUInteger)n * 2; // pcm16 sample count
    } else if ((n % 4) == 0 && n >= 640 && n <= 16384) {
        const float *f = (const float *)p;
        NSUInteger ns = (NSUInteger)n / 4;
        if (ns >= 2) {
            float a = f[0], b = f[1];
            if (a > -1.5f && a < 1.5f && b > -1.5f && b < 1.5f) {
                NSMutableData *pcm = [NSMutableData dataWithLength:ns * 2];
                int16_t *dst = (int16_t *)pcm.mutableBytes;
                for (NSUInteger i = 0; i < ns; i++) {
                    float v = f[i];
                    if (v > 1.f) v = 1.f; if (v < -1.f) v = -1.f;
                    dst[i] = (int16_t)(v * 32767.f);
                }
                if (track == WCRTrackMic) [[WCRSessionManager shared] appendMic:pcm.bytes length:pcm.length sampleRate:sr];
                else [[WCRSessionManager shared] appendRemote:pcm.bytes length:pcm.length sampleRate:sr];
                WCRLog("pcm %s %s nBytes=%ld (f32bytes) sr=%.0f", track == WCRTrackMic ? "mic" : "remote", sel_getName(cmd), (long)n, sr);
                (void)self;
                return;
            }
        }
    }

    if (track == WCRTrackMic) {
        [[WCRSessionManager shared] appendMic:bytes length:byteLen sampleRate:sr];
    } else {
        [[WCRSessionManager shared] appendRemote:bytes length:byteLen sampleRate:sr];
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

// NSUInteger / size_t length variants (common on arm64 WeChat builds)
static void wcr_mic_v_pQ(id self, SEL cmd, void *p, NSUInteger n) {
    void (*orig)(id, SEL, void *, NSUInteger) = (void (*)(id, SEL, void *, NSUInteger))WCRLookupOrig(self, cmd);
    WCRCapturePtr(self, cmd, WCRTrackMic, p, (NSInteger)n, 0);
    if (orig) orig(self, cmd, p, n);
}
static void wcr_remote_v_pQ(id self, SEL cmd, void *p, NSUInteger n) {
    void (*orig)(id, SEL, void *, NSUInteger) = (void (*)(id, SEL, void *, NSUInteger))WCRLookupOrig(self, cmd);
    WCRCapturePtr(self, cmd, WCRTrackRemote, p, (NSInteger)n, 0);
    if (orig) orig(self, cmd, p, n);
}
static void wcr_mic_v_pQQ(id self, SEL cmd, void *p, NSUInteger n, NSUInteger sr) {
    void (*orig)(id, SEL, void *, NSUInteger, NSUInteger) = (void (*)(id, SEL, void *, NSUInteger, NSUInteger))WCRLookupOrig(self, cmd);
    WCRCapturePtr(self, cmd, WCRTrackMic, p, (NSInteger)n, (double)sr);
    if (orig) orig(self, cmd, p, n, sr);
}
static void wcr_remote_v_pQQ(id self, SEL cmd, void *p, NSUInteger n, NSUInteger sr) {
    void (*orig)(id, SEL, void *, NSUInteger, NSUInteger) = (void (*)(id, SEL, void *, NSUInteger, NSUInteger))WCRLookupOrig(self, cmd);
    WCRCapturePtr(self, cmd, WCRTrackRemote, p, (NSInteger)n, (double)sr);
    if (orig) orig(self, cmd, p, n, sr);
}
static void wcr_mic_v_idQ(id self, SEL cmd, id data, NSUInteger n) {
    void (*orig)(id, SEL, id, NSUInteger) = (void (*)(id, SEL, id, NSUInteger))WCRLookupOrig(self, cmd);
    if ([data isKindOfClass:[NSData class]]) WCRCaptureData(self, cmd, WCRTrackMic, data, 0);
    else if (data) WCRCapturePtr(self, cmd, WCRTrackMic, (__bridge const void *)data, (NSInteger)n, 0);
    if (orig) orig(self, cmd, data, n);
}
static void wcr_remote_v_idQ(id self, SEL cmd, id data, NSUInteger n) {
    void (*orig)(id, SEL, id, NSUInteger) = (void (*)(id, SEL, id, NSUInteger))WCRLookupOrig(self, cmd);
    if ([data isKindOfClass:[NSData class]]) WCRCaptureData(self, cmd, WCRTrackRemote, data, 0);
    else if (data) WCRCapturePtr(self, cmd, WCRTrackRemote, (__bridge const void *)data, (NSInteger)n, 0);
    if (orig) orig(self, cmd, data, n);
}

static BOOL WCRTypeIsIntish(char t) {
    return (t == 'i' || t == 'I' || t == 's' || t == 'S' || t == 'l' || t == 'L' || t == 'q' || t == 'Q' || t == 'B' || t == 'c' || t == 'C');
}
static BOOL WCRTypeIsPtrish(char t) {
    return (t == '^' || t == '*' || t == 'r'); // pointer / char* / const
}

static IMP WCRPickAudioIMP(Method m, WCRTrack track) {
    if (!m) return NULL;
    unsigned argc = method_getNumberOfArguments(m);
    char t0[32] = {0}, t2[32] = {0}, t3[32] = {0}, t4[32] = {0};
    method_getReturnType(m, t0, sizeof(t0));
    if (argc >= 3) method_getArgumentType(m, 2, t2, sizeof(t2));
    if (argc >= 4) method_getArgumentType(m, 3, t3, sizeof(t3));
    if (argc >= 5) method_getArgumentType(m, 4, t4, sizeof(t4));
    // Non-void would corrupt return; keep strict void for safety.
    if (t0[0] != 'v') return NULL;
    if (argc == 3 && t2[0] == '@') {
        return track == WCRTrackMic ? (IMP)wcr_mic_v_id : (IMP)wcr_remote_v_id;
    }
    if (argc == 4 && WCRTypeIsPtrish(t2[0]) && WCRTypeIsIntish(t3[0])) {
        // Prefer 64-bit length trampoline when encoding is q/Q/L/l
        if (t3[0] == 'Q' || t3[0] == 'q' || t3[0] == 'L' || t3[0] == 'l') {
            return track == WCRTrackMic ? (IMP)wcr_mic_v_pQ : (IMP)wcr_remote_v_pQ;
        }
        return track == WCRTrackMic ? (IMP)wcr_mic_v_pi : (IMP)wcr_remote_v_pi;
    }
    if (argc == 4 && t2[0] == '@' && WCRTypeIsIntish(t3[0])) {
        if (t3[0] == 'Q' || t3[0] == 'q' || t3[0] == 'L' || t3[0] == 'l') {
            return track == WCRTrackMic ? (IMP)wcr_mic_v_idQ : (IMP)wcr_remote_v_idQ;
        }
        return track == WCRTrackMic ? (IMP)wcr_mic_v_idi : (IMP)wcr_remote_v_idi;
    }
    if (argc == 5 && WCRTypeIsPtrish(t2[0]) && WCRTypeIsIntish(t3[0]) && WCRTypeIsIntish(t4[0])) {
        if (t3[0] == 'Q' || t3[0] == 'q' || t3[0] == 'L' || t3[0] == 'l' ||
            t4[0] == 'Q' || t4[0] == 'q' || t4[0] == 'L' || t4[0] == 'l') {
            return track == WCRTrackMic ? (IMP)wcr_mic_v_pQQ : (IMP)wcr_remote_v_pQQ;
        }
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

#pragma mark - AudioUnit PCM capture (fallback when ObjC PCM selectors miss)
// Substrate-free path: fishhook-style dyld symbol rebind for TrollFools / no-MSHookFunction.
// Optional MSHookFunction remains preferred when present.

typedef OSStatus (*WCRAudioOutputUnitStart_t)(AudioUnit ci);
typedef OSStatus (*WCRAudioUnitRender_t)(AudioUnit inUnit,
                                         AudioUnitRenderActionFlags *ioActionFlags,
                                         const AudioTimeStamp *inTimeStamp,
                                         UInt32 inOutputBusNumber,
                                         UInt32 inNumberFrames,
                                         AudioBufferList *ioData);
typedef OSStatus (*WCRAudioUnitSetProperty_t)(AudioUnit inUnit,
                                              AudioUnitPropertyID inID,
                                              AudioUnitScope inScope,
                                              AudioUnitElement inElement,
                                              const void *inData,
                                              UInt32 inDataSize);
typedef void (*WCRMSHookFunction_t)(void *symbol, void *replace, void **result);

static WCRAudioOutputUnitStart_t gWCROrigAudioOutputUnitStart = NULL;
static WCRAudioUnitRender_t gWCROrigAudioUnitRender = NULL;
static WCRAudioUnitSetProperty_t gWCROrigAudioUnitSetProperty = NULL;
static AudioStreamBasicDescription gWCRLastASBD;
static BOOL gWCRHasASBD = NO;

typedef struct {
    AURenderCallback origProc;
    void *origRefCon;
    AudioUnit unit;
    BOOL isInput; // YES=mic input callback, NO=output render callback
} WCRWrappedCB;
static WCRWrappedCB gWCRWrappedCBs[8];
static int gWCRWrappedCBCount = 0;

static void WCRCaptureAudioBufferList(AudioBufferList *ioData, WCRTrack track, double srHint) {
    if (!ioData || ioData->mNumberBuffers == 0) return;
    if (!WCREnabled()) return;
    // Soft-start: answering a call may miss ObjC lifecycle selectors on 8.0.71.
    if (![[WCRSessionManager shared] isRecording]) {
        WCRMaybeBeginFromAudioTap("au-buffer");
        if (![[WCRSessionManager shared] isRecording]) return;
    }
    for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
        AudioBuffer *buf = &ioData->mBuffers[i];
        if (!buf || !buf->mData || buf->mDataByteSize == 0) continue;
        if (buf->mDataByteSize > 2 * 1024 * 1024) continue;

        const void *src = buf->mData;
        NSUInteger byteSize = (NSUInteger)buf->mDataByteSize;
        double sr = srHint;
        if (sr < 8000.0 && gWCRHasASBD && gWCRLastASBD.mSampleRate >= 8000.0) sr = gWCRLastASBD.mSampleRate;

        // Float32 -> PCM16
        BOOL maybeFloat = NO;
        if (gWCRHasASBD) {
            maybeFloat = ((gWCRLastASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0) || gWCRLastASBD.mBitsPerChannel == 32;
        } else {
            // heuristic: values look like floats in [-1,1]
            if (byteSize >= 8 && (byteSize % 4) == 0) {
                const float *f = (const float *)src;
                float a = f[0], b = f[1];
                if ((a > -1.5f && a < 1.5f) && (b > -1.5f && b < 1.5f)) maybeFloat = YES;
            }
        }

        if (maybeFloat && (byteSize % 4) == 0) {
            NSUInteger n = byteSize / 4;
            NSMutableData *pcm = [NSMutableData dataWithLength:n * 2];
            int16_t *dst = (int16_t *)pcm.mutableBytes;
            const float *f = (const float *)src;
            UInt32 ch = buf->mNumberChannels > 0 ? buf->mNumberChannels : (gWCRHasASBD ? gWCRLastASBD.mChannelsPerFrame : 1);
            if (ch <= 1) {
                for (NSUInteger k = 0; k < n; k++) {
                    float v = f[k];
                    if (v > 1.f) v = 1.f; if (v < -1.f) v = -1.f;
                    dst[k] = (int16_t)(v * 32767.f);
                }
            } else {
                // downmix interleaved to mono
                NSUInteger frames = n / ch;
                pcm = [NSMutableData dataWithLength:frames * 2];
                dst = (int16_t *)pcm.mutableBytes;
                for (NSUInteger fr = 0; fr < frames; fr++) {
                    float sum = 0;
                    for (UInt32 c = 0; c < ch; c++) sum += f[fr * ch + c];
                    float v = sum / (float)ch;
                    if (v > 1.f) v = 1.f; if (v < -1.f) v = -1.f;
                    dst[fr] = (int16_t)(v * 32767.f);
                }
            }
            if (track == WCRTrackMic) [[WCRSessionManager shared] appendMic:pcm.bytes length:pcm.length sampleRate:sr];
            else [[WCRSessionManager shared] appendRemote:pcm.bytes length:pcm.length sampleRate:sr];
        } else {
            // assume PCM16 (possibly multi-channel interleaved)
            UInt32 ch = buf->mNumberChannels > 0 ? buf->mNumberChannels : (gWCRHasASBD ? gWCRLastASBD.mChannelsPerFrame : 1);
            if (ch > 1 && (byteSize % (2 * ch)) == 0) {
                NSUInteger frames = byteSize / (2 * ch);
                NSMutableData *pcm = [NSMutableData dataWithLength:frames * 2];
                int16_t *dst = (int16_t *)pcm.mutableBytes;
                const int16_t *s = (const int16_t *)src;
                for (NSUInteger fr = 0; fr < frames; fr++) {
                    int32_t sum = 0;
                    for (UInt32 c = 0; c < ch; c++) sum += s[fr * ch + c];
                    dst[fr] = (int16_t)(sum / (int32_t)ch);
                }
                if (track == WCRTrackMic) [[WCRSessionManager shared] appendMic:pcm.bytes length:pcm.length sampleRate:sr];
                else [[WCRSessionManager shared] appendRemote:pcm.bytes length:pcm.length sampleRate:sr];
            } else {
                if (track == WCRTrackMic) [[WCRSessionManager shared] appendMic:src length:byteSize sampleRate:sr];
                else [[WCRSessionManager shared] appendRemote:src length:byteSize sampleRate:sr];
            }
        }
    }
}

static OSStatus WCRRenderNotify(void *inRefCon,
                                AudioUnitRenderActionFlags *ioActionFlags,
                                const AudioTimeStamp *inTimeStamp,
                                UInt32 inBusNumber,
                                UInt32 inNumberFrames,
                                AudioBufferList *ioData) {
    (void)inRefCon; (void)inTimeStamp; (void)inNumberFrames;
    if (!ioActionFlags || !ioData) return noErr;
    if (!WCREnabled() || ![[WCRSessionManager shared] isRecording]) return noErr;
    BOOL post = ((*ioActionFlags) & kAudioUnitRenderAction_PostRender) != 0;
    if (!post) return noErr;
    // Bus 0 output (speaker / remote mix). Input is captured via AudioUnitRender / input callback.
    if (inBusNumber == 0) {
        WCRCaptureAudioBufferList(ioData, WCRTrackRemote, gWCRHasASBD ? gWCRLastASBD.mSampleRate : 0);
    }
    return noErr;
}

static void WCRCacheUnitASBD(AudioUnit unit) {
    if (!unit) return;
    AudioStreamBasicDescription asbd = {0};
    UInt32 sz = sizeof(asbd);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, &sz) == noErr && asbd.mSampleRate > 0) {
        gWCRLastASBD = asbd;
        gWCRHasASBD = YES;
        return;
    }
    sz = sizeof(asbd);
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &asbd, &sz) == noErr && asbd.mSampleRate > 0) {
        gWCRLastASBD = asbd;
        gWCRHasASBD = YES;
    }
}

static void WCRTryAttachUnit(AudioUnit unit) {
    if (!unit) return;
    WCRCacheUnitASBD(unit);
    // Adding notify twice is mostly harmless; AudioUnit keeps a list.
    AudioUnitAddRenderNotify(unit, WCRRenderNotify, NULL);
}

static OSStatus WCRWrappedAUCallback(void *inRefCon,
                                     AudioUnitRenderActionFlags *ioActionFlags,
                                     const AudioTimeStamp *inTimeStamp,
                                     UInt32 inBusNumber,
                                     UInt32 inNumberFrames,
                                     AudioBufferList *ioData) {
    WCRWrappedCB *wrap = (WCRWrappedCB *)inRefCon;
    OSStatus st = noErr;
    if (wrap && wrap->origProc) {
        st = wrap->origProc(wrap->origRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData);
    }
    if (st == noErr && ioData && WCREnabled() && [[WCRSessionManager shared] isRecording]) {
        WCRTrack track = (wrap && wrap->isInput) ? WCRTrackMic : WCRTrackRemote;
        // For output render, bus0 is speaker; for input, bus1/0 may carry mic.
        if (!wrap || wrap->isInput || inBusNumber == 0) {
            WCRCaptureAudioBufferList(ioData, track, gWCRHasASBD ? gWCRLastASBD.mSampleRate : 0);
        }
    }
    return st;
}

static WCRWrappedCB *WCRStoreWrappedCB(AudioUnit unit, BOOL isInput, AURenderCallback origProc, void *origRefCon) {
    if (!origProc) return NULL;
    for (int i = 0; i < gWCRWrappedCBCount; i++) {
        if (gWCRWrappedCBs[i].unit == unit && gWCRWrappedCBs[i].isInput == isInput) {
            gWCRWrappedCBs[i].origProc = origProc;
            gWCRWrappedCBs[i].origRefCon = origRefCon;
            return &gWCRWrappedCBs[i];
        }
    }
    if (gWCRWrappedCBCount >= (int)(sizeof(gWCRWrappedCBs) / sizeof(gWCRWrappedCBs[0]))) {
        // overwrite oldest slot
        WCRWrappedCB *w = &gWCRWrappedCBs[0];
        w->unit = unit; w->isInput = isInput; w->origProc = origProc; w->origRefCon = origRefCon;
        return w;
    }
    WCRWrappedCB *w = &gWCRWrappedCBs[gWCRWrappedCBCount++];
    w->unit = unit; w->isInput = isInput; w->origProc = origProc; w->origRefCon = origRefCon;
    return w;
}

static BOOL WCRLooksLikeActiveCallAudio(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        NSString *cat = s.category ?: @"";
        NSString *mode = s.mode ?: @"";
        if (WCRCategoryLooksLikeCall(cat, mode)) return YES;
        NSString *cl = cat.lowercaseString ?: @"";
        if ([cl containsString:@"playandrecord"] || [cl containsString:@"record"]) {
            if (WCRIsLikelyInCallUI()) return YES;
            if (s.isInputAvailable) return YES;
        }
        if (WCRIsLikelyInCallUI()) return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

static void WCRMaybeBeginFromAudioTap(const char *why) {
    if (!WCREnabled()) return;
    if ([[WCRSessionManager shared] isRecording]) return;
    BOOL audioLooks = NO;
    BOOL uiLooks = NO;
    @try { audioLooks = WCRLooksLikeActiveCallAudio(); } @catch (__unused NSException *e) {}
    @try { uiLooks = WCRIsLikelyInCallUI(); } @catch (__unused NSException *e) {}
    // AudioUnit start during answer is itself a strong signal on 8.0.71.
    BOOL auSignal = (why && (strstr(why, "AudioOutputUnitStart") || strstr(why, "au-buffer") || strstr(why, "poll-")));
    if (!(audioLooks || uiLooks || auSignal)) return;
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (now - last < 0.45) return;
    last = now;
    @try {
        WCROnCallMaybeStarted();
        NSString *hint = WCRGetLastContactName() ?: WCRGetLastContactHint() ?: WCRScrapeCallUIContactName();
        if (hint.length == 0 || WCRLooksLikeBadDisplayName(hint)) hint = @"\u901a\u8bdd";
        [[WCRSessionManager shared] beginWithReason:[NSString stringWithUTF8String:(why ?: "au-start")]
                                       contactHint:hint
                                        sampleRate:WCRPreferredSampleRate()];
        WCRInfo("auto-begin session from audio tap (%s) audio=%d ui=%d", why ?: "?", audioLooks?1:0, uiLooks?1:0);
    } @catch (__unused NSException *e) {}
}

static OSStatus WCRRepl_AudioOutputUnitStart(AudioUnit ci) {
    WCRTryAttachUnit(ci);
    WCRMaybeBeginFromAudioTap("AudioOutputUnitStart");
    if (gWCROrigAudioOutputUnitStart) return gWCROrigAudioOutputUnitStart(ci);
    return -1;
}

static OSStatus WCRRepl_AudioUnitRender(AudioUnit inUnit,
                                        AudioUnitRenderActionFlags *ioActionFlags,
                                        const AudioTimeStamp *inTimeStamp,
                                        UInt32 inOutputBusNumber,
                                        UInt32 inNumberFrames,
                                        AudioBufferList *ioData) {
    OSStatus st = noErr;
    if (gWCROrigAudioUnitRender) {
        st = gWCROrigAudioUnitRender(inUnit, ioActionFlags, inTimeStamp, inOutputBusNumber, inNumberFrames, ioData);
    }
    // Pulling input bus typically means mic frames; bus0 may also be used by some stacks.
    if (st == noErr && ioData) {
        WCRTrack track = (inOutputBusNumber == 1) ? WCRTrackMic : WCRTrackRemote;
        WCRCaptureAudioBufferList(ioData, track, gWCRHasASBD ? gWCRLastASBD.mSampleRate : 0);
    }
    return st;
}

static OSStatus WCRRepl_AudioUnitSetProperty(AudioUnit inUnit,
                                             AudioUnitPropertyID inID,
                                             AudioUnitScope inScope,
                                             AudioUnitElement inElement,
                                             const void *inData,
                                             UInt32 inDataSize) {
    // Wrap RemoteIO input/output callbacks so we see PCM even without RenderNotify.
    if (inData && inDataSize >= sizeof(AURenderCallbackStruct) &&
        (inID == kAudioUnitProperty_SetRenderCallback || inID == kAudioOutputUnitProperty_SetInputCallback)) {
        const AURenderCallbackStruct *src = (const AURenderCallbackStruct *)inData;
        if (src->inputProc && src->inputProc != WCRWrappedAUCallback) {
            BOOL isInput = (inID == kAudioOutputUnitProperty_SetInputCallback);
            WCRWrappedCB *wrap = WCRStoreWrappedCB(inUnit, isInput, src->inputProc, src->inputProcRefCon);
            if (wrap) {
                AURenderCallbackStruct repl = {0};
                repl.inputProc = WCRWrappedAUCallback;
                repl.inputProcRefCon = wrap;
                WCRCacheUnitASBD(inUnit);
                if (gWCROrigAudioUnitSetProperty) {
                    return gWCROrigAudioUnitSetProperty(inUnit, inID, inScope, inElement, &repl, sizeof(repl));
                }
            }
        }
    }
    if (gWCROrigAudioUnitSetProperty) {
        OSStatus st = gWCROrigAudioUnitSetProperty(inUnit, inID, inScope, inElement, inData, inDataSize);
        if (st == noErr && inID == kAudioUnitProperty_StreamFormat) {
            WCRCacheUnitASBD(inUnit);
        }
        return st;
    }
    return -1;
}

#pragma mark - fishhook-style rebind (classic + dyld chained fixups)

#ifndef SEG_DATA_CONST
#define SEG_DATA_CONST "__DATA_CONST"
#endif
#ifndef LC_DYLD_CHAINED_FIXUPS
#define LC_DYLD_CHAINED_FIXUPS 0x80000034
#endif
#ifndef DYLD_CHAINED_PTR_ARM64E
#define DYLD_CHAINED_PTR_ARM64E                 1
#define DYLD_CHAINED_PTR_64                      2
#define DYLD_CHAINED_PTR_32                      3
#define DYLD_CHAINED_PTR_32_CACHE                4
#define DYLD_CHAINED_PTR_32_FIRMWARE             5
#define DYLD_CHAINED_PTR_64_OFFSET               6
#define DYLD_CHAINED_PTR_ARM64E_KERNEL           7
#define DYLD_CHAINED_PTR_64_KERNEL_CACHE         8
#define DYLD_CHAINED_PTR_ARM64E_USERLAND         9
#define DYLD_CHAINED_PTR_ARM64E_FIRMWARE         10
#define DYLD_CHAINED_PTR_X86_64_KERNEL_CACHE     11
#define DYLD_CHAINED_PTR_ARM64E_USERLAND24       12
#endif
#ifndef DYLD_CHAINED_IMPORT
#define DYLD_CHAINED_IMPORT          1
#define DYLD_CHAINED_IMPORT_ADDEND   2
#define DYLD_CHAINED_IMPORT_ADDEND64 3
#endif

typedef struct {
    const char *name;
    void *replacement;
    void **replaced;
    int slots;
} WCRRebindEntry;

typedef struct {
    uint32_t fixups_version;
    uint32_t starts_offset;
    uint32_t imports_offset;
    uint32_t symbols_offset;
    uint32_t imports_count;
    uint32_t imports_format;
    uint32_t symbols_format;
} wcr_chained_fixups_header;

typedef struct {
    uint32_t seg_count;
    uint32_t seg_info_offset[1];
} wcr_chained_starts_in_image;

typedef struct {
    uint32_t size;
    uint16_t page_size;
    uint16_t pointer_format;
    uint64_t segment_offset;
    uint32_t max_valid_pointer;
    uint16_t page_count;
    uint16_t page_start[1];
} wcr_chained_starts_in_segment;

typedef struct {
    uint32_t lib_ordinal :  8;
    uint32_t weak_import :  1;
    uint32_t name_offset : 23;
} wcr_chained_import;

static int WCRMakeWritableAndSet(void **slot, void *value, void **outOld) {
    if (!slot) return 0;
    vm_address_t page = (vm_address_t)slot;
    vm_size_t psz = 0;
    host_page_size(mach_host_self(), &psz);
    if (psz == 0) psz = 16384;
    page &= ~(vm_address_t)(psz - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, psz, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), page, psz, 0, VM_PROT_READ | VM_PROT_WRITE);
        if (kr != KERN_SUCCESS) return 0;
    }
    if (outOld && *outOld == NULL) *outOld = *slot;
    *slot = value;
    vm_protect(mach_task_self(), page, psz, 0, VM_PROT_READ);
    return 1;
}

static const char *WCRChainedImportName(const wcr_chained_fixups_header *hdr, uint32_t ordinal) {
    if (!hdr || ordinal >= hdr->imports_count) return NULL;
    const uint8_t *base = (const uint8_t *)hdr;
    const char *symbols = (const char *)(base + hdr->symbols_offset);
    const uint8_t *imports = base + hdr->imports_offset;
    uint32_t name_offset = 0;
    if (hdr->imports_format == DYLD_CHAINED_IMPORT) {
        const wcr_chained_import *imp = &((const wcr_chained_import *)imports)[ordinal];
        name_offset = imp->name_offset;
    } else if (hdr->imports_format == DYLD_CHAINED_IMPORT_ADDEND) {
        const uint8_t *p = imports + ordinal * 8;
        const wcr_chained_import *imp = (const wcr_chained_import *)p;
        name_offset = imp->name_offset;
    } else if (hdr->imports_format == DYLD_CHAINED_IMPORT_ADDEND64) {
        const uint8_t *p = imports + ordinal * 16;
        const wcr_chained_import *imp = (const wcr_chained_import *)p;
        name_offset = imp->name_offset;
    } else {
        return NULL;
    }
    const char *name = symbols + name_offset;
    if (!name || !name[0]) return NULL;
    return (name[0] == '_') ? (name + 1) : name;
}

static int WCRMatchRebindName(const char *impName, WCRRebindEntry *entries, size_t ne) {
    if (!impName) return -1;
    for (size_t e = 0; e < ne; e++) {
        if (strcmp(impName, entries[e].name) == 0) return (int)e;
    }
    return -1;
}

// After dyld processes chained fixups, bind=1 is cleared. Rebind by pointer value instead.
static uintptr_t WCRStripPtr(uintptr_t p) {
    return p & 0x0000FFFFFFFFFFFFULL;
}

static void WCRRebindPointerSlot(void **slot, WCRRebindEntry *entries, size_t ne, int idx) {
    if (idx < 0 || !slot || !entries) return;
    void *cur = *slot;
    if (!cur) return;
    if (cur == entries[idx].replacement) {
        entries[idx].slots += 1;
        return;
    }
    if (WCRMakeWritableAndSet(slot, entries[idx].replacement, entries[idx].replaced)) {
        entries[idx].slots += 1;
    }
}

static void WCRRebindByPointerValueInImage(const struct mach_header *header,
                                           intptr_t slide,
                                           WCRRebindEntry *entries,
                                           size_t ne,
                                           void **targets) {
    if (!header || !entries || !targets || ne == 0) return;
#if defined(__LP64__)
    typedef struct mach_header_64 wcr_mh_t;
    typedef struct segment_command_64 wcr_seg_t;
    const uint32_t expected_magic = MH_MAGIC_64;
    const uint32_t seg_cmd = LC_SEGMENT_64;
#else
    typedef struct mach_header wcr_mh_t;
    typedef struct segment_command wcr_seg_t;
    const uint32_t expected_magic = MH_MAGIC;
    const uint32_t seg_cmd = LC_SEGMENT;
#endif
    if (header->magic != expected_magic) return;
    const wcr_mh_t *mh = (const wcr_mh_t *)header;
    uintptr_t cur = (uintptr_t)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == seg_cmd) {
            const wcr_seg_t *seg = (const wcr_seg_t *)lc;
            if (!(strcmp(seg->segname, SEG_DATA) == 0 ||
                  strcmp(seg->segname, SEG_DATA_CONST) == 0 ||
                  strcmp(seg->segname, "__DATA_DIRTY") == 0 ||
                  strcmp(seg->segname, "__AUTH_CONST") == 0 ||
                  strcmp(seg->segname, "__AUTH") == 0)) {
                cur += lc->cmdsize;
                continue;
            }
            if (seg->vmsize == 0 || seg->vmsize > 32 * 1024 * 1024) {
                cur += lc->cmdsize;
                continue;
            }
            uint8_t *base = (uint8_t *)((uintptr_t)slide + (uintptr_t)seg->vmaddr);
            size_t bytes = (size_t)seg->vmsize;
            uintptr_t start = ((uintptr_t)base + sizeof(void *) - 1) & ~(sizeof(void *) - 1);
            uintptr_t end = (uintptr_t)base + bytes;
            for (uintptr_t addr = start; addr + sizeof(void *) <= end; addr += sizeof(void *)) {
                void **slot = (void **)addr;
                void *val = *slot;
                if (!val) continue;
                uintptr_t stripped = WCRStripPtr((uintptr_t)val);
                for (size_t e = 0; e < ne; e++) {
                    if (!targets[e]) continue;
                    if (stripped == WCRStripPtr((uintptr_t)targets[e])) {
                        WCRRebindPointerSlot(slot, entries, ne, (int)e);
                        break;
                    }
                }
            }
        }
        cur += lc->cmdsize;
    }
}

static void WCRRebindChainedSlot(void **slot, WCRRebindEntry *entries, size_t ne, int idx) {
    if (idx < 0 || !slot) return;
    if (*slot == entries[idx].replacement) {
        entries[idx].slots += 1;
        return;
    }
    if (WCRMakeWritableAndSet(slot, entries[idx].replacement, entries[idx].replaced)) {
        entries[idx].slots += 1;
    }
}

static void WCRWalkChainedStarts(const struct mach_header *header,
                                 intptr_t slide,
                                 const wcr_chained_fixups_header *fixups,
                                 WCRRebindEntry *entries,
                                 size_t ne) {
    if (!header || !fixups || !entries) return;
    const uint8_t *base = (const uint8_t *)fixups;
    const wcr_chained_starts_in_image *starts = (const wcr_chained_starts_in_image *)(base + fixups->starts_offset);
    for (uint32_t segIndex = 0; segIndex < starts->seg_count; segIndex++) {
        uint32_t off = starts->seg_info_offset[segIndex];
        if (off == 0) continue;
        const wcr_chained_starts_in_segment *seg = (const wcr_chained_starts_in_segment *)(base + fixups->starts_offset + off);
        uint16_t format = seg->pointer_format;
        BOOL okFmt = (format == DYLD_CHAINED_PTR_64 ||
                      format == DYLD_CHAINED_PTR_64_OFFSET ||
                      format == DYLD_CHAINED_PTR_ARM64E ||
                      format == DYLD_CHAINED_PTR_ARM64E_USERLAND ||
                      format == DYLD_CHAINED_PTR_ARM64E_USERLAND24);
        if (!okFmt) continue;
        uint8_t *segBase = (uint8_t *)((uintptr_t)header + (uintptr_t)seg->segment_offset);
        (void)slide;
        for (uint16_t pageIndex = 0; pageIndex < seg->page_count; pageIndex++) {
            uint16_t pageStart = seg->page_start[pageIndex];
            if (pageStart == 0xFFFF) continue;
            if (pageStart & 0x8000) continue; // multi-start not handled
            uint8_t *page = segBase + ((uint32_t)pageIndex * seg->page_size);
            uint32_t chainOffset = pageStart;
            for (;;) {
                uint8_t *loc = page + chainOffset;
                uint64_t raw = *(uint64_t *)loc;
                uint32_t next = 0;
                int bind = 0;
                uint32_t ordinal = 0;
                if (format == DYLD_CHAINED_PTR_64 || format == DYLD_CHAINED_PTR_64_OFFSET) {
                    next = (uint32_t)((raw >> 51) & 0xFFF);
                    bind = (int)((raw >> 63) & 1);
                    if (bind) ordinal = (uint32_t)(raw & 0xFFFFFF);
                } else {
                    next = (uint32_t)((raw >> 52) & 0x7FF);
                    bind = (int)((raw >> 63) & 1);
                    if (bind) {
                        if (format == DYLD_CHAINED_PTR_ARM64E_USERLAND24) ordinal = (uint32_t)(raw & 0xFFFFFF);
                        else ordinal = (uint32_t)(raw & 0xFFFF);
                    }
                }
                if (bind) {
                    const char *iname = WCRChainedImportName(fixups, ordinal);
                    int idx = WCRMatchRebindName(iname, entries, ne);
                    if (idx >= 0) WCRRebindChainedSlot((void **)loc, entries, ne, idx);
                }
                if (next == 0) break;
                chainOffset += next * sizeof(uint64_t);
                if (chainOffset > seg->page_size) break;
            }
        }
    }
}

static void WCRPerformRebindInImage(const struct mach_header *header,
                                    intptr_t slide,
                                    WCRRebindEntry *entries,
                                    size_t ne) {
    if (!header || !entries || ne == 0) return;
#if defined(__LP64__)
    typedef struct mach_header_64 wcr_mh_t;
    typedef struct segment_command_64 wcr_seg_t;
    typedef struct section_64 wcr_sec_t;
    typedef struct nlist_64 wcr_nlist_t;
    const uint32_t expected_magic = MH_MAGIC_64;
    const uint32_t seg_cmd = LC_SEGMENT_64;
#else
    typedef struct mach_header wcr_mh_t;
    typedef struct segment_command wcr_seg_t;
    typedef struct section wcr_sec_t;
    typedef struct nlist wcr_nlist_t;
    const uint32_t expected_magic = MH_MAGIC;
    const uint32_t seg_cmd = LC_SEGMENT;
#endif
    if (header->magic != expected_magic) return;
    const wcr_mh_t *mh = (const wcr_mh_t *)header;
    uintptr_t cur = (uintptr_t)(mh + 1);
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;
    const struct linkedit_data_command *chained_cmd = NULL;
    const wcr_seg_t *linkedit = NULL;
    intptr_t linkedit_base = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cur;
        if (lc->cmd == seg_cmd) {
            const wcr_seg_t *seg = (const wcr_seg_t *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                linkedit = seg;
                linkedit_base = (intptr_t)slide + (intptr_t)seg->vmaddr - (intptr_t)seg->fileoff;
            }
        } else if (lc->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (const struct dysymtab_command *)lc;
        } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) {
            chained_cmd = (const struct linkedit_data_command *)lc;
        }
        cur += lc->cmdsize;
    }
    if (symtab_cmd && dysymtab_cmd && linkedit && dysymtab_cmd->nindirectsyms > 0) {
        wcr_nlist_t *symtab = (wcr_nlist_t *)(linkedit_base + symtab_cmd->symoff);
        char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
        uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);
        cur = (uintptr_t)(mh + 1);
        for (uint32_t i = 0; i < mh->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)cur;
            if (lc->cmd == seg_cmd) {
                const wcr_seg_t *seg = (const wcr_seg_t *)lc;
                if (strcmp(seg->segname, SEG_DATA) == 0 ||
                    strcmp(seg->segname, SEG_DATA_CONST) == 0 ||
                    strcmp(seg->segname, "__DATA_DIRTY") == 0 ||
                    strcmp(seg->segname, "__AUTH_CONST") == 0) {
                    wcr_sec_t *sections = (wcr_sec_t *)((uintptr_t)seg + sizeof(wcr_seg_t));
                    for (uint32_t j = 0; j < seg->nsects; j++) {
                        wcr_sec_t *sect = &sections[j];
                        uint32_t stype = sect->flags & SECTION_TYPE;
                        if (stype != S_LAZY_SYMBOL_POINTERS && stype != S_NON_LAZY_SYMBOL_POINTERS) continue;
                        if (sect->reserved1 >= dysymtab_cmd->nindirectsyms) continue;
                        uint32_t *indirect = indirect_symtab + sect->reserved1;
                        void **bindings = (void **)((uintptr_t)slide + (uintptr_t)sect->addr);
                        uint32_t count = (uint32_t)(sect->size / sizeof(void *));
                        for (uint32_t k = 0; k < count; k++) {
                            uint32_t symIndex = indirect[k];
                            if ((symIndex & INDIRECT_SYMBOL_ABS) != 0 || (symIndex & INDIRECT_SYMBOL_LOCAL) != 0) continue;
                            if (symIndex >= symtab_cmd->nsyms) continue;
                            uint32_t strx = symtab[symIndex].n_un.n_strx;
                            if (strx == 0) continue;
                            const char *name = strtab + strx;
                            if (!name || !name[0]) continue;
                            const char *cmp = (name[0] == '_') ? (name + 1) : name;
                            int idx = WCRMatchRebindName(cmp, entries, ne);
                            if (idx >= 0) {
                                if (bindings[k] == entries[idx].replacement) entries[idx].slots += 1;
                                else if (WCRMakeWritableAndSet(&bindings[k], entries[idx].replacement, entries[idx].replaced)) entries[idx].slots += 1;
                            }
                        }
                    }
                }
            }
            cur += lc->cmdsize;
        }
    }
    if (chained_cmd && linkedit) {
        const wcr_chained_fixups_header *fixups =
            (const wcr_chained_fixups_header *)(linkedit_base + chained_cmd->dataoff);
        if (fixups && fixups->fixups_version == 0) {
            WCRWalkChainedStarts(header, slide, fixups, entries, ne);
        }
    }
}

static int WCRRebindSymbols(WCRRebindEntry *entries, size_t ne) {
    if (!entries || ne == 0) return 0;
    for (size_t e = 0; e < ne; e++) entries[e].slots = 0;

    void *targets[8] = {0};
    size_t use = ne > 8 ? 8 : ne;
    for (size_t e = 0; e < use; e++) {
        if (!entries[e].name) continue;
        void *p = dlsym(RTLD_DEFAULT, entries[e].name);
        targets[e] = p;
    }

    uint32_t imgCount = _dyld_image_count();
    for (uint32_t i = 0; i < imgCount; i++) {
        const struct mach_header *hdr = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (!hdr) continue;
        const char *imgName = _dyld_get_image_name(i);
        if (imgName && strstr(imgName, "WCallRecorder")) continue;
        // Prefer audio-related images first pass is full scan; value scan is the real fix.
        WCRPerformRebindInImage(hdr, slide, entries, use);
        WCRRebindByPointerValueInImage(hdr, slide, entries, use, targets);
    }
    int slots = 0;
    for (size_t e = 0; e < ne; e++) slots += entries[e].slots;
    return slots;
}


static void WCRInstallAudioUnitHooks(void) {
    // Do NOT early-return: WeChat may load audio images later; rebind each call.
    void *pStart = dlsym(RTLD_DEFAULT, "AudioOutputUnitStart");
    void *pRender = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    void *pSetProp = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    if (!pStart && !pRender && !pSetProp) {
        WCRInfo("AudioUnit symbols missing from process");
        return;
    }

    int ok = 0;
    const char *via = "none";
    static atomic_int sMSHookDone = 0;

    // 1) Prefer MSHookFunction when Substrate/ElleKit is present (only once).
    if (!atomic_load(&sMSHookDone)) {
        WCRMSHookFunction_t hookFn = (WCRMSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
        if (!hookFn) {
            const char *libs[] = {
                "/usr/lib/libsubstrate.dylib",
                "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                "@rpath/CydiaSubstrate.framework/CydiaSubstrate",
                "/var/jb/usr/lib/libsubstrate.dylib",
                "/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
                "/usr/lib/libellekit.dylib",
                "/var/jb/usr/lib/libellekit.dylib",
                NULL
            };
            for (int i = 0; libs[i]; i++) {
                void *h = dlopen(libs[i], RTLD_LAZY);
                if (!h) continue;
                hookFn = (WCRMSHookFunction_t)dlsym(h, "MSHookFunction");
                if (hookFn) break;
            }
        }
        if (hookFn) {
            if (pStart && !gWCROrigAudioOutputUnitStart) {
                hookFn(pStart, (void *)WCRRepl_AudioOutputUnitStart, (void **)&gWCROrigAudioOutputUnitStart);
                if (gWCROrigAudioOutputUnitStart) ok++;
            }
            if (pRender && !gWCROrigAudioUnitRender) {
                hookFn(pRender, (void *)WCRRepl_AudioUnitRender, (void **)&gWCROrigAudioUnitRender);
                if (gWCROrigAudioUnitRender) ok++;
            }
            if (pSetProp && !gWCROrigAudioUnitSetProperty) {
                hookFn(pSetProp, (void *)WCRRepl_AudioUnitSetProperty, (void **)&gWCROrigAudioUnitSetProperty);
                if (gWCROrigAudioUnitSetProperty) ok++;
            }
            if (ok > 0) {
                via = "MSHookFunction";
                atomic_store(&sMSHookDone, 1);
            }
        }
    } else if (gWCROrigAudioOutputUnitStart || gWCROrigAudioUnitRender || gWCROrigAudioUnitSetProperty) {
        ok = 1;
        via = "MSHookFunction";
    }

    // 2) Always re-run fishhook/chained rebind so newly loaded WeChat images get patched.
    //    Keep existing originals if already captured (do not reset to NULL).
    {
        WCRRebindEntry entries[] = {
            { "AudioOutputUnitStart", (void *)WCRRepl_AudioOutputUnitStart, (void **)&gWCROrigAudioOutputUnitStart, 0 },
            { "AudioUnitRender", (void *)WCRRepl_AudioUnitRender, (void **)&gWCROrigAudioUnitRender, 0 },
            { "AudioUnitSetProperty", (void *)WCRRepl_AudioUnitSetProperty, (void **)&gWCROrigAudioUnitSetProperty, 0 },
        };
        int slots = WCRRebindSymbols(entries, sizeof(entries) / sizeof(entries[0]));
        if (entries[0].slots > 0 && !gWCROrigAudioOutputUnitStart && pStart)
            gWCROrigAudioOutputUnitStart = (WCRAudioOutputUnitStart_t)pStart;
        if (entries[1].slots > 0 && !gWCROrigAudioUnitRender && pRender)
            gWCROrigAudioUnitRender = (WCRAudioUnitRender_t)pRender;
        if (entries[2].slots > 0 && !gWCROrigAudioUnitSetProperty && pSetProp)
            gWCROrigAudioUnitSetProperty = (WCRAudioUnitSetProperty_t)pSetProp;

        int rb = 0;
        if (entries[0].slots > 0) rb++;
        if (entries[1].slots > 0) rb++;
        if (entries[2].slots > 0) rb++;
        if (rb > 0) {
            if (ok == 0) via = "fishhook";
            ok = ok > rb ? ok : rb;
            WCRInfo("AudioUnit rebind slots=%d classic/chained (start=%d render=%d set=%d)",
                    slots, entries[0].slots, entries[1].slots, entries[2].slots);
        }
    }

    if (ok > 0) {
        atomic_store(&gWCRAudioUnitHooksInstalled, 1);
        atomic_store(&gWCRAudioHooksInstalled, 1);
        WCRInfo("AudioUnit C hooks ready (%d) via %s", ok, via);
    } else {
        WCRInfo("AudioUnit hooks NOT installed (no MSHookFunction / fishhook miss)");
    }
}


#pragma mark - Runtime PCM probe (learn commercial ObjC-sink model)

static BOOL WCRLooksLikePCMLength(NSInteger n) {
    if (n < 160 || n > 64 * 1024) return NO;
    if (n % 2 != 0) return NO; // PCM16
    // Common VoIP frames: 10/20ms at 8/16/24/32/48k mono/stereo
    static const int kCommon[] = {
        160, 320, 480, 640, 960, 1280, 1920, 2560, 3840, 4096, 5760, 7680, 8192
    };
    for (int i = 0; i < (int)(sizeof(kCommon)/sizeof(kCommon[0])); i++) {
        if (n == kCommon[i]) return YES;
        if (n % kCommon[i] == 0 && n / kCommon[i] <= 8) return YES;
    }
    // Accept other even sizes in plausible range during active call.
    return (n >= 320 && n <= 16384);
}

static void WCRProbePromote(id self, SEL cmd, WCRTrack track, const void *p, NSInteger n, double sr) {
    if (!self || !cmd || !p || n <= 0) return;
    if (![[WCRSessionManager shared] isRecording]) return;
    if (!WCRLooksLikePCMLength(n)) return;
    // Quick energy check: reject all-zero / near-silent headers only when clearly empty.
    const int16_t *s = (const int16_t *)p;
    NSInteger samples = n / 2;
    NSInteger check = samples < 32 ? samples : 32;
    int nonzero = 0;
    for (NSInteger i = 0; i < check; i++) {
        if (s[i] != 0) { nonzero++; break; }
    }
    // Still accept zeros early in call (comfort noise may be low). Capture anyway if length matches.
    WCRCapturePtr(self, cmd, track, p, n, sr);
    atomic_fetch_add(&gWCRProbeHits, 1);
    const char *cname = class_getName(object_getClass(self));
    const char *sname = sel_getName(cmd);
    if (cname && sname) {
        WCRPersistDiscoveredHook([NSString stringWithUTF8String:cname],
                                 [NSString stringWithUTF8String:sname],
                                 track == WCRTrackMic ? @"mic" : @"remote");
        WCRInfo("PROBE hit -[%s %s] track=%s n=%ld sr=%.0f", cname, sname,
                track == WCRTrackMic ? "mic" : "remote", (long)n, sr);
    }
    (void)nonzero;
}

// Probe trampolines: always call original first to minimize behavior change, then sample.
static void wcr_probe_mic_v_pi(id self, SEL cmd, void *p, int n) {
    void (*orig)(id, SEL, void *, int) = (void (*)(id, SEL, void *, int))WCRLookupOrig(self, cmd);
    if (orig) orig(self, cmd, p, n);
    WCRProbePromote(self, cmd, WCRTrackMic, p, n, 0);
}
static void wcr_probe_remote_v_pi(id self, SEL cmd, void *p, int n) {
    void (*orig)(id, SEL, void *, int) = (void (*)(id, SEL, void *, int))WCRLookupOrig(self, cmd);
    if (orig) orig(self, cmd, p, n);
    WCRProbePromote(self, cmd, WCRTrackRemote, p, n, 0);
}
static void wcr_probe_mic_v_pQ(id self, SEL cmd, void *p, NSUInteger n) {
    void (*orig)(id, SEL, void *, NSUInteger) = (void (*)(id, SEL, void *, NSUInteger))WCRLookupOrig(self, cmd);
    if (orig) orig(self, cmd, p, n);
    WCRProbePromote(self, cmd, WCRTrackMic, p, (NSInteger)n, 0);
}
static void wcr_probe_remote_v_pQ(id self, SEL cmd, void *p, NSUInteger n) {
    void (*orig)(id, SEL, void *, NSUInteger) = (void (*)(id, SEL, void *, NSUInteger))WCRLookupOrig(self, cmd);
    if (orig) orig(self, cmd, p, n);
    WCRProbePromote(self, cmd, WCRTrackRemote, p, (NSInteger)n, 0);
}
static void wcr_probe_mic_v_id(id self, SEL cmd, id data) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    if (orig) orig(self, cmd, data);
    if ([data isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)data;
        WCRProbePromote(self, cmd, WCRTrackMic, d.bytes, (NSInteger)d.length, 0);
    }
}
static void wcr_probe_remote_v_id(id self, SEL cmd, id data) {
    void (*orig)(id, SEL, id) = (void (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    if (orig) orig(self, cmd, data);
    if ([data isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)data;
        WCRProbePromote(self, cmd, WCRTrackRemote, d.bytes, (NSInteger)d.length, 0);
    }
}
static void wcr_probe_mic_v_pii(id self, SEL cmd, void *p, int n, int sr) {
    void (*orig)(id, SEL, void *, int, int) = (void (*)(id, SEL, void *, int, int))WCRLookupOrig(self, cmd);
    if (orig) orig(self, cmd, p, n, sr);
    WCRProbePromote(self, cmd, WCRTrackMic, p, n, (double)sr);
}
static void wcr_probe_remote_v_pii(id self, SEL cmd, void *p, int n, int sr) {
    void (*orig)(id, SEL, void *, int, int) = (void (*)(id, SEL, void *, int, int))WCRLookupOrig(self, cmd);
    if (orig) orig(self, cmd, p, n, sr);
    WCRProbePromote(self, cmd, WCRTrackRemote, p, n, (double)sr);
}

static IMP WCRPickProbeIMP(Method m, WCRTrack track) {
    // Reuse signature rules, but map to probe trampolines.
    if (!m) return NULL;
    unsigned argc = method_getNumberOfArguments(m);
    char t0[32] = {0}, t2[32] = {0}, t3[32] = {0}, t4[32] = {0};
    method_getReturnType(m, t0, sizeof(t0));
    if (t0[0] != 'v') return NULL;
    if (argc >= 3) method_getArgumentType(m, 2, t2, sizeof(t2));
    if (argc >= 4) method_getArgumentType(m, 3, t3, sizeof(t3));
    if (argc >= 5) method_getArgumentType(m, 4, t4, sizeof(t4));
    if (argc == 3 && t2[0] == '@') {
        return track == WCRTrackMic ? (IMP)wcr_probe_mic_v_id : (IMP)wcr_probe_remote_v_id;
    }
    if (argc == 4 && WCRTypeIsPtrish(t2[0]) && WCRTypeIsIntish(t3[0])) {
        if (t3[0] == 'Q' || t3[0] == 'q' || t3[0] == 'L' || t3[0] == 'l') {
            return track == WCRTrackMic ? (IMP)wcr_probe_mic_v_pQ : (IMP)wcr_probe_remote_v_pQ;
        }
        return track == WCRTrackMic ? (IMP)wcr_probe_mic_v_pi : (IMP)wcr_probe_remote_v_pi;
    }
    if (argc == 5 && WCRTypeIsPtrish(t2[0]) && WCRTypeIsIntish(t3[0]) && WCRTypeIsIntish(t4[0])) {
        return track == WCRTrackMic ? (IMP)wcr_probe_mic_v_pii : (IMP)wcr_probe_remote_v_pii;
    }
    return NULL;
}

static BOOL WCRSelectorLooksProbeWorthy(const char *sn) {
    if (!sn) return NO;
    if (WCRCaseContains(sn, "pcm")) return YES;
    if (WCRCaseContains(sn, "audiodata")) return YES;
    if (WCRCaseContains(sn, "micdata")) return YES;
    if (WCRCaseContains(sn, "playdata")) return YES;
    if (WCRCaseContains(sn, "recorddata")) return YES;
    if (WCRCaseContains(sn, "speakerdata")) return YES;
    if (WCRCaseContains(sn, "farend")) return YES;
    if (WCRCaseContains(sn, "nearend")) return YES;
    if (WCRCaseContains(sn, "inputdata")) return YES;
    if (WCRCaseContains(sn, "outputdata")) return YES;
    if (WCRCaseContains(sn, "capturedata")) return YES;
    if (WCRCaseContains(sn, "voicedata")) return YES;
    if (WCRCaseContains(sn, "renderdata")) return YES;
    if (WCRCaseContains(sn, "captureddata")) return YES;
    if (WCRCaseContains(sn, "callback") && (WCRCaseContains(sn, "audio") || WCRCaseContains(sn, "record") ||
                                            WCRCaseContains(sn, "play") || WCRCaseContains(sn, "pcm") ||
                                            WCRCaseContains(sn, "mic") || WCRCaseContains(sn, "unit"))) return YES;
    if (WCRCaseContains(sn, "frame") && (WCRCaseContains(sn, "audio") || WCRCaseContains(sn, "pcm") || WCRCaseContains(sn, "data") || WCRCaseContains(sn, "voice"))) return YES;
    if (WCRCaseContains(sn, "buffer") && (WCRCaseContains(sn, "audio") || WCRCaseContains(sn, "pcm") || WCRCaseContains(sn, "record") || WCRCaseContains(sn, "play") || WCRCaseContains(sn, "voice"))) return YES;
    if ((WCRCaseContains(sn, "data") || WCRCaseContains(sn, "buffer") || WCRCaseContains(sn, "frame") || WCRCaseContains(sn, "sample")) &&
        (WCRCaseContains(sn, "length") || WCRCaseContains(sn, "len") || WCRCaseContains(sn, "size") || WCRCaseContains(sn, "bytes") || WCRCaseContains(sn, "count"))) {
        if (WCRCaseContains(sn, "audio") || WCRCaseContains(sn, "mic") || WCRCaseContains(sn, "play") ||
            WCRCaseContains(sn, "record") || WCRCaseContains(sn, "speaker") || WCRCaseContains(sn, "remote") ||
            WCRCaseContains(sn, "local") || WCRCaseContains(sn, "input") || WCRCaseContains(sn, "output") ||
            WCRCaseContains(sn, "voip") || WCRCaseContains(sn, "ilink") || WCRCaseContains(sn, "talk") ||
            WCRCaseContains(sn, "voice") || WCRCaseContains(sn, "pcm") || WCRCaseContains(sn, "render") ||
            WCRCaseContains(sn, "capture") || WCRCaseContains(sn, "near") || WCRCaseContains(sn, "far")) {
            return YES;
        }
    }
    if ((WCRCaseContains(sn, "audio") || WCRCaseContains(sn, "pcm") || WCRCaseContains(sn, "voice") ||
         WCRCaseContains(sn, "mic") || WCRCaseContains(sn, "speaker")) &&
        (WCRCaseContains(sn, "data") || WCRCaseContains(sn, "buffer") || WCRCaseContains(sn, "frame") ||
         WCRCaseContains(sn, "sample") || WCRCaseContains(sn, "packet"))) {
        return YES;
    }
    return NO;
}

static BOOL WCRClassLooksAudioRelated(const char *name) {
    if (!name) return NO;
    return (WCRCaseContains(name, "voip") || WCRCaseContains(name, "ilink") || WCRCaseContains(name, "audio") ||
            WCRCaseContains(name, "multitalk") || WCRCaseContains(name, "talk") || WCRCaseContains(name, "conf") ||
            WCRCaseContains(name, "device") || WCRCaseContains(name, "record") || WCRCaseContains(name, "player") ||
            WCRCaseContains(name, "cloud") || WCRCaseContains(name, "live") || WCRCaseContains(name, "auunit") ||
            WCRCaseContains(name, "audiounit") || WCRCaseContains(name, "pipe") || WCRCaseContains(name, "engine") ||
            WCRCaseContains(name, "mic") || WCRCaseContains(name, "speaker") || WCRCaseContains(name, "wxaudio") ||
            WCRCaseContains(name, "wcaudio") || WCRCaseContains(name, "tp") || WCRCaseContains(name, "mtvoip"));
}

static void WCRInstallDiscoveredAudioHooks(void) {
    int hooked = 0;
    for (NSArray *item in WCRLoadDiscoveredHooks()) {
        if (item.count < 3) continue;
        Class cls = NSClassFromString(item[0]);
        SEL sel = NSSelectorFromString(item[1]);
        NSString *track = item[2];
        if (!cls || !sel) continue;
        if (WCRHookAudioSelector(cls, sel, [track isEqualToString:@"remote"] ? WCRTrackRemote : WCRTrackMic)) hooked++;
    }
    if (hooked > 0) {
        atomic_store(&gWCRAudioHooksInstalled, 1);
        WCRInfo("discovered audio hooks installed: %d", hooked);
    }
}

static BOOL WCRClassLooksStrongAudio(const char *name) {
    if (!name) return NO;
    return (WCRCaseContains(name, "voipaudio") || WCRCaseContains(name, "auaudio") ||
            WCRCaseContains(name, "ilinkaudio") || WCRCaseContains(name, "wcaudio") ||
            WCRCaseContains(name, "mmaudio") || WCRCaseContains(name, "audiounit") ||
            WCRCaseContains(name, "audiodevice") || WCRCaseContains(name, "audioengine") ||
            WCRCaseContains(name, "audiodev") || WCRCaseContains(name, "cloudvoip") ||
            WCRCaseContains(name, "voipmp") || WCRCaseContains(name, "confaudio") ||
            WCRCaseContains(name, "liveaudio") || WCRCaseContains(name, "datapipe"));
}

static void WCRDumpAudioCandidates(void) {
    @try {
        NSString *root = [[WCRSessionManager shared] rootDir];
        if (!root.length) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *path = [root stringByAppendingPathComponent:@"candidates.txt"];
        NSMutableString *out = [NSMutableString stringWithFormat:@"# WCallRecorder v%@ candidates\n", kWCRPluginVersion];
        unsigned int count = 0;
        Class *classes = objc_copyClassList(&count);
        int listed = 0;
        for (unsigned int i = 0; i < count && listed < 400; i++) {
            Class cls = classes[i];
            const char *cname = class_getName(cls);
            if (!WCRClassLooksAudioRelated(cname)) continue;
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(cls, &mcount);
            for (unsigned int j = 0; j < mcount && listed < 400; j++) {
                Method m = methods[j];
                SEL sel = method_getName(m);
                const char *sn = sel_getName(sel);
                if (!sn) continue;
                unsigned argc = method_getNumberOfArguments(m);
                if (argc < 3 || argc > 6) continue;
                char ret[8] = {0}; method_getReturnType(m, ret, sizeof(ret));
                if (ret[0] != 'v') continue;
                char t2[32] = {0}; method_getArgumentType(m, 2, t2, sizeof(t2));
                if (!(t2[0] == '^' || t2[0] == '*' || t2[0] == '@' || t2[0] == 'r')) continue;
                BOOL nameHit = WCRSelectorLooksProbeWorthy(sn) || WCRClassLooksStrongAudio(cname);
                if (!nameHit) continue;
                [out appendFormat:@"-[%s %s] argc=%u t2=%s\n", cname, sn, argc, t2];
                listed++;
            }
            if (methods) free(methods);
        }
        free(classes);
        [out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        WCRInfo("wrote %d audio candidates -> %@", listed, path);
    } @catch (__unused NSException *e) {}
}

static void WCRInstallProbeAudioHooks(void) {
    if (!WCRProbeEnabled()) return;
    BOOL recording = NO;
    @try { recording = [[WCRSessionManager shared] isRecording]; } @catch (__unused NSException *e) {}
    if (!recording) return;

    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSinceReferenceDate;
    if (now - last < 1.2) return;
    last = now;

    static BOOL dumped = NO;
    if (!dumped) {
        dumped = YES;
        WCRDumpAudioCandidates();
    }

    int hooked = 0;
    int budget = 160;

    NSMutableArray<Class> *targets = [NSMutableArray array];
    for (NSString *cname in WCRPreferredClasses()) {
        Class cls = NSClassFromString(cname);
        if (cls) [targets addObject:cls];
    }
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count && targets.count < 320; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!WCRClassLooksAudioRelated(name)) continue;
        if (![targets containsObject:cls]) [targets addObject:cls];
    }
    free(classes);

    for (Class cls in targets) {
        if (hooked >= budget) break;
        const char *cname = class_getName(cls);
        BOOL strong = WCRClassLooksStrongAudio(cname);
        Class walk = cls;
        int depth = strong ? 2 : 1;
        for (int d = 0; d < depth && walk && hooked < budget; d++, walk = class_getSuperclass(walk)) {
            unsigned int mcount = 0;
            Method *methods = class_copyMethodList(walk, &mcount);
            for (unsigned int i = 0; i < mcount; i++) {
                if (hooked >= budget) break;
                Method m = methods[i];
                SEL sel = method_getName(m);
                const char *sn = sel_getName(sel);
                if (!sn) continue;
                NSString *snLow = [[NSString stringWithUTF8String:sn] lowercaseString];
                if (WCRKeyLooksLifecycle(snLow)) continue;
                if (WCRCaseContains(sn, "tableView") || WCRCaseContains(sn, "collectionView") ||
                    WCRCaseContains(sn, "gesture") || WCRCaseContains(sn, "button") ||
                    WCRCaseContains(sn, "drawRect") || WCRCaseContains(sn, "layout")) continue;

                BOOL nameHit = WCRSelectorLooksProbeWorthy(sn);
                if (!nameHit && !strong) continue;
                if (!nameHit && strong) {
                    unsigned argc = method_getNumberOfArguments(m);
                    char ret[8] = {0}; method_getReturnType(m, ret, sizeof(ret));
                    if (ret[0] != 'v') continue;
                    if (argc < 3 || argc > 5) continue;
                    char t2[16] = {0}; method_getArgumentType(m, 2, t2, sizeof(t2));
                    if (!(t2[0] == '^' || t2[0] == '*' || t2[0] == '@' || t2[0] == 'r')) continue;
                    if (argc >= 4) {
                        char t3[16] = {0}; method_getArgumentType(m, 3, t3, sizeof(t3));
                        if (!(WCRTypeIsIntish(t3[0]) || t3[0] == '@')) continue;
                    }
                }

                BOOL isMic = (WCRCaseContains(sn, "mic") || WCRCaseContains(sn, "record") ||
                              WCRCaseContains(sn, "capture") || WCRCaseContains(sn, "local") ||
                              WCRCaseContains(sn, "input") || WCRCaseContains(sn, "send") ||
                              WCRCaseContains(sn, "near") || WCRCaseContains(sn, "uplink"));
                BOOL isRemote = (WCRCaseContains(sn, "play") || WCRCaseContains(sn, "speaker") ||
                                 WCRCaseContains(sn, "remote") || WCRCaseContains(sn, "output") ||
                                 WCRCaseContains(sn, "recv") || WCRCaseContains(sn, "render") ||
                                 WCRCaseContains(sn, "far") || WCRCaseContains(sn, "playback") ||
                                 WCRCaseContains(sn, "downlink"));
                WCRTrack track = WCRTrackMic;
                if (isRemote && !isMic) track = WCRTrackRemote;
                else if (isMic && !isRemote) track = WCRTrackMic;
                else if (isRemote) track = WCRTrackRemote;

                IMP repl = WCRPickProbeIMP(m, track);
                if (!repl) continue;
                if (WCRHookInstance(walk, sel, repl)) {
                    hooked++;
                    WCRLog("probe hooked -[%s %s] track=%s", class_getName(walk), sn, track == WCRTrackMic ? "mic" : "remote");
                }
            }
            if (methods) free(methods);
        }
    }

    if (hooked > 0) {
        atomic_store(&gWCRProbeHooksInstalled, 1);
        atomic_store(&gWCRAudioHooksInstalled, 1);
        WCRInfo("probe audio hooks newly installed: %d (hits=%d)", hooked, atomic_load(&gWCRProbeHits));
    }
}

// BOOL-returning accept APIs are common on modern WeChat; void-only trampolines skipped them.
static BOOL wcr_call_bool_void(id self, SEL cmd) {
    BOOL (*orig)(id, SEL) = (BOOL (*)(id, SEL))WCRLookupOrig(self, cmd);
    BOOL ret = orig ? orig(self, cmd) : NO;
    @try {
        if (WCREnabled()) {
            WCROnCallMaybeStarted();
            NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle-bool";
            [[WCRSessionManager shared] beginWithReason:reason contactHint:WCRGetLastContactHint() sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    return ret;
}
static BOOL wcr_call_bool_id(id self, SEL cmd, id a) {
    BOOL (*orig)(id, SEL, id) = (BOOL (*)(id, SEL, id))WCRLookupOrig(self, cmd);
    BOOL ret = orig ? orig(self, cmd, a) : NO;
    @try {
        if (WCREnabled()) {
            WCRNoteContactFromObject(a);
            WCROnCallMaybeStarted();
            NSString *reason = [NSString stringWithUTF8String:sel_getName(cmd)] ?: @"lifecycle-bool";
            NSString *hint = WCRGetLastContactName() ?: WCRGetLastContactHint() ?: WCRSafeDesc(a);
            [[WCRSessionManager shared] beginWithReason:reason contactHint:hint sampleRate:WCRPreferredSampleRate()];
        }
    } @catch (__unused NSException *e) {}
    return ret;
}

static IMP WCRPickLifecycleIMP(const char *selName, unsigned argc) {
    if (!selName) return NULL;
    // Only return trampolines whose ABI matches argc. Wrong arity = crash on answer.
    if (strcmp(selName, "StartRecordAndPlayForVoIPWithRoomID:roomKey:") == 0) {
        return (argc == 4) ? (IMP)wcr_call_room : NULL;
    }
    if (strcmp(selName, "ilinkOpenWindowWithContact:msgWrap:isCaller:from:startInApp:isEarMode:isAudioMode:") == 0) {
        return (argc == 9) ? (IMP)wcr_ilink_open : NULL;
    }
    if (strcmp(selName, "joinMultiTalkWithGroup:roomId:roomKey:joinSuccessHandler:") == 0) {
        return (argc == 6) ? (IMP)wcr_call_join : NULL;
    }
    if (strcmp(selName, "createMultiTalkWithContacts:withChatroomUsername:") == 0) {
        return (argc == 4) ? (IMP)wcr_call_id_id : NULL;
    }
    if (strstr(selName, "Stop") || strstr(selName, "Hangup") || strstr(selName, "Reject") ||
        strstr(selName, "Cancel") || strstr(selName, "CloseWindow") || strstr(selName, "hangup") ||
        strstr(selName, "reject") || strstr(selName, "cancel") || strstr(selName, "End") ||
        strstr(selName, "endCall") || strstr(selName, "dismiss") || strstr(selName, "Dismiss")) {
        if (!(strstr(selName, "Start") || strstr(selName, "Enter") || strstr(selName, "Invite") ||
              strstr(selName, "Accept") || strstr(selName, "Begin") || strstr(selName, "Open") ||
              strstr(selName, "Create") || strstr(selName, "Join") || strstr(selName, "show") ||
              strstr(selName, "Show") || strstr(selName, "present") || strstr(selName, "Present"))) {
            if (argc == 2) return (IMP)wcr_stop;
            if (argc == 3) return (IMP)wcr_stop_id;
            return NULL;
        }
    }
    if (argc == 2) return (IMP)wcr_call_void;
    if (argc == 3) return (IMP)wcr_call_id;
    if (argc == 4) return (IMP)wcr_call_id_id;
    return NULL; // refuse unknown high-arity signatures
}

static void WCRInstallCallViewControllerHooks(void) {
    // Subclasses often override viewDidAppear without calling super; hook those classes directly.
    static atomic_int installed = 0;
    if (atomic_load(&installed) > 64) return;
    int hooked = 0;
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    SEL appear = @selector(viewDidAppear:);
    SEL willAppear = @selector(viewWillAppear:);
    for (unsigned int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *cn = class_getName(cls);
        if (!WCRClassNameLooksCallUI(cn)) continue;
        if (WCRClassHasOwnInstanceMethod(cls, appear)) {
            if (WCRHookInstance(cls, appear, (IMP)WCR_repl_vc_viewDidAppear)) {
                hooked++;
                WCRLog("call-vc hook -[%s viewDidAppear:]", cn ?: "?");
            }
        }
        // viewWillAppear is even earlier on answer transition.
        if (WCRClassHasOwnInstanceMethod(cls, willAppear)) {
            if (WCRHookInstance(cls, willAppear, (IMP)WCR_repl_vc_viewDidAppear)) {
                hooked++;
                WCRLog("call-vc hook -[%s viewWillAppear:]", cn ?: "?");
            }
        }
        if (hooked + atomic_load(&installed) > 96) break;
    }
    if (classes) free(classes);
    if (hooked > 0) {
        atomic_fetch_add(&installed, hooked);
        atomic_fetch_add(&gWCRLifecycleHooksInstalled, hooked);
        WCRInfo("call VC appear hooks +%d (total installed~%d)", hooked, (int)atomic_load(&installed));
    }
}

static void WCRInstallLifecycle(void) {
    // Commercial plaintext lifecycle selectors (from WCallRecorder.dylib strings).
    static const char *selNames[] = {
        // commercial plaintext lifecycle
        "StartRecordAndPlayForVoIP",
        "StartRecordAndPlayForVoIPInterruptionRecovery",
        "StartRecordAndPlayForMuTalk",
        "StartRecordAndPlayForIlink:",
        "StartRecordAndPlayForVoIPWithRoomID:roomKey:",
        "StopForVoIP",
        "StopForMultiTalk",
        "StopForIlink",
        // answer / accept / invite (incoming call critical)
        "Accept",
        "accept",
        "AcceptCall",
        "acceptCall",
        "AcceptVoIP",
        "acceptVoIP",
        "onAccept",
        "onAccept:",
        "OnAccept",
        "OnAccept:",
        "onAcceptCall",
        "onAcceptCall:",
        "onAcceptVoIP",
        "onAcceptVoIP:",
        "acceptWithContact:",
        "accept",
        "Accept",
        "answer",
        "Answer",
        "answerCall",
        "AnswerCall",
        "acceptVoipInvite",
        "AcceptVoipInvite",
        "acceptVoIPInvite",
        "onAccept",
        "onAccept:",
        "OnAccept",
        "OnAccept:",
        "realAccept",
        "AcceptCall",
        "acceptCall",
        "acceptCall:",
        "AcceptCall:",
        "acceptCallWithContact:",
        "AcceptCallWithContact:",
        "onAcceptSubCallMultiTalk:",
        "onMultiTalkMainViewControllerAcceptWithGroup:",
        "onInviteMultiTalk:",
        "onInvite",
        "onInvite:",
        "OnInvite",
        "OnInvite:",
        "onInviteCall",
        "onInviteCall:",
        "onRecvInvite",
        "onRecvInvite:",
        "receiveInviteFromUsername:",
        "receiveInviteFromUsername:withRoomID:",
        // open / show call UI
        "ilinkOpenWindowWithContact:isCaller:monoMsg:msgLocalID:isEarMode:isAudioMode:fromScene:isIlink:isIlinkAudioMode:",
        "ilinkOpenWindowWithContact:",
        "OpenWindowWithContact:",
        "openWindowWithContact:",
        "openVoipViewWithContact:",
        "openVideoCallWithContact:",
        "openVoiceCallWithContact:",
        "showVoipView",
        "showVoipView:",
        "showCallKit",
        "reportAccept",
        "reportAccepted",
        "reportInvite",
        // start / join
        "StartVoIP",
        "startVoIP",
        "StartVoIPByUser:",
        "startVoipWithContact:",
        "StartVoipWithContact:",
        "startTalk",
        "StartTalk",
        "startTalk:",
        "onEnterMultiTalk:",
        "onCreateMultiTalk:",
        "JoinMultiTalk:",
        "joinMultiTalk:",
        "createMultiTalk:",
        // hangup / end
        "Hangup",
        "hangup",
        "HangUp",
        "hangUp",
        "HangupCall",
        "hangupCall",
        "HangupVoIP",
        "hangupVoIP",
        "EndCall",
        "endCall",
        "Reject",
        "reject",
        "RejectCall",
        "rejectCall",
        "CancelCall",
        "cancelCall",
        "CloseWindow",
        "closeWindow",
        "closeVoipView",
        "dismissVoipView",
        "onCallEnd",
        "onCallEnd:",
        "OnCallEnd",
        "OnCallEnd:",
        "onVoipCallEnd",
        "onVoipCallEnd:",
        NULL
    };
    int hooked = 0;
    for (int i = 0; selNames[i]; i++) {
        SEL sel = sel_registerName(selNames[i]);
        NSMutableArray *classes = [NSMutableArray array];
        for (NSString *name in WCRPreferredClasses()) {
            Class cls = NSClassFromString(name);
            if (cls && class_getInstanceMethod(cls, sel)) [classes addObject:cls];
            Class meta = cls ? object_getClass((id)cls) : Nil;
            if (meta && class_getInstanceMethod(meta, sel) && ![classes containsObject:meta]) {
                [classes addObject:meta];
            }
        }
        unsigned int count = 0;
        Class *all = objc_copyClassList(&count);
        for (unsigned int c = 0; c < count; c++) {
            Class cls = all[c];
            if (!class_getInstanceMethod(cls, sel)) continue;
            const char *cn = class_getName(cls);
            if (!cn) continue;
            BOOL prefer = WCRCaseContains(cn, "voip") || WCRCaseContains(cn, "multitalk") ||
                          WCRCaseContains(cn, "ilink") || WCRCaseContains(cn, "audio") ||
                          WCRCaseContains(cn, "talk") || WCRCaseContains(cn, "conf") ||
                          WCRCaseContains(cn, "cloud") || WCRCaseContains(cn, "live") ||
                          WCRCaseContains(cn, "component") || WCRCaseContains(cn, "mgr");
            if (prefer || classes.count == 0) {
                if (![classes containsObject:cls]) [classes addObject:cls];
            }
        }
        if (all) free(all);

        // Short generic names like Accept/Hangup are dangerous unless class looks VoIP-related.
        BOOL shortSel = (strlen(selNames[i]) < 12) && (strchr(selNames[i], ':') == NULL);
        for (Class cls in classes) {
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            const char *cn = class_getName(cls);
            if (shortSel) {
                if (!cn) continue;
                BOOL voipCls = WCRCaseContains(cn, "voip") || WCRCaseContains(cn, "ilink") ||
                               WCRCaseContains(cn, "multitalk") || WCRCaseContains(cn, "talk") ||
                               WCRCaseContains(cn, "call") || WCRCaseContains(cn, "conf") ||
                               WCRCaseContains(cn, "mono") || WCRCaseContains(cn, "room");
                if (!voipCls) continue;
            }
            unsigned argc = method_getNumberOfArguments(m);
            char ret[8] = {0};
            method_getReturnType(m, ret, sizeof(ret));
            // Allow BOOL return for accept-like APIs (common on modern WeChat).
            BOOL retOK = (ret[0] == 'v' || ret[0] == 'B' || ret[0] == 'c');
            if (!retOK) continue;
            IMP repl = NULL;
            if (ret[0] == 'B' || ret[0] == 'c') {
                if (argc == 2) repl = (IMP)wcr_call_bool_void;
                else if (argc == 3) repl = (IMP)wcr_call_bool_id;
                else continue;
            } else {
                repl = WCRPickLifecycleIMP(selNames[i], argc);
            }
            if (!repl) continue;
            if (WCRHookInstance(cls, sel, repl)) {
                hooked++;
                WCRLog("lifecycle ok -[%s %s] argc=%u", class_getName(cls), selNames[i], argc);
            }
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
        "PutPcmData:length:", "putPcmData:length:",
        "WritePcmData:length:", "writePcmData:length:",
        "onLocalAudioData:length:", "localAudioData:length:",
        "pushMicAudio:length:", "PushMicData:length:",
        "recordAudioData:length:", "captureAudioData:length:",
        "OnRecData:length:", "onRecData:length:",
        "inputData:length:", "InputData:length:",
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
        "GetPcmData:length:", "getPcmData:length:",
        "onRemoteAudioData:length:", "remoteAudioData:length:",
        "pushPlayAudio:length:", "PushPlayData:length:",
        "playAudioData:length:", "outputData:length:", "OutputData:length:",
        "OnPlayData:length:", "speakerData:length:",
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
    // Safe-ish scan over VoIP/audio related classes only.
    // Always allowed while a session is recording; otherwise Verbose only.
    BOOL recording = NO;
    @try { recording = [[WCRSessionManager shared] isRecording]; } @catch (__unused NSException *e) {}
    if (!WCRVerboseFlag() && !recording) return;

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


#pragma mark - Commercial-style rescan / AVAudioSession / dyld

static BOOL WCRCategoryLooksLikeCall(NSString *cat, NSString *mode) {
    if (cat.length == 0 && mode.length == 0) return NO;
    NSString *c = cat.lowercaseString ?: @"";
    NSString *m = mode.lowercaseString ?: @"";
    if ([c containsString:@"playandrecord"] || [c containsString:@"record"]) return YES;
    if ([c isEqualToString:[AVAudioSessionCategoryPlayAndRecord lowercaseString]]) return YES;
    if ([c isEqualToString:[AVAudioSessionCategoryRecord lowercaseString]]) return YES;
    if ([m containsString:@"voicechat"] || [m containsString:@"videochat"] ||
        [m containsString:@"voip"] || [m containsString:@"gamechat"]) return YES;
    if ([m isEqualToString:[AVAudioSessionModeVoiceChat lowercaseString]]) return YES;
    if ([m isEqualToString:[AVAudioSessionModeVideoChat lowercaseString]]) return YES;
    return NO;
}

static void WCRNoteCallAudioMaybeStarted(NSString *why, NSString *cat, NSString *mode) {
    if (!WCREnabled()) return;
    BOOL looks = WCRCategoryLooksLikeCall(cat, mode);
    if (!looks) {
        @try { if (WCRIsLikelyInCallUI()) looks = YES; } @catch (__unused NSException *e) {}
    }
    if (!looks) return;
    @try {
        WCROnCallMaybeStarted();
        NSString *hint = WCRGetLastContactName() ?: WCRGetLastContactHint() ?: WCRScrapeCallUIContactName();
        if (hint.length == 0 || WCRLooksLikeBadDisplayName(hint)) hint = @"\u901a\u8bdd";
        [[WCRSessionManager shared] beginWithReason:(why ?: @"AVAudioSession") contactHint:hint sampleRate:WCRPreferredSampleRate()];
    } @catch (__unused NSException *e) {}
}

static void WCRNoteCallAudioMaybeEnded(NSString *why) {
    @try {
        if (![[WCRSessionManager shared] isRecording]) return;
        BOOL inCall = NO;
        @try { inCall = WCRIsLikelyInCallUI(); } @catch (__unused NSException *e) {}
        if (inCall) {
            WCRInfo("AVAudioSession end signal ignored (still in call UI): %@", why ?: @"?");
            return;
        }
        [[WCRSessionManager shared] endWithReason:(why ?: @"AVAudioSession-end")];
    } @catch (__unused NSException *e) {}
}

static BOOL (*WCR_orig_setCategory1)(id, SEL, id, id *) = NULL;
static BOOL WCR_repl_setCategory1(id self, SEL cmd, id category, id *err) {
    BOOL ok = YES;
    if (WCR_orig_setCategory1) ok = WCR_orig_setCategory1(self, cmd, category, err);
    else {
        IMP o = WCRLookupOrig(self, cmd);
        if (o) ok = ((BOOL(*)(id, SEL, id, id *))o)(self, cmd, category, err);
    }
    @try {
        NSString *cat = [category isKindOfClass:[NSString class]] ? (NSString *)category : [category description];
        WCRNoteCallAudioMaybeStarted(@"setCategory", cat, nil);
        WCRLog("AVAudioSession setCategory:%@", cat);
    } @catch (__unused NSException *e) {}
    return ok;
}

static BOOL (*WCR_orig_setCategory4)(id, SEL, id, id, NSUInteger, id *) = NULL;
static BOOL WCR_repl_setCategory4(id self, SEL cmd, id category, id mode, NSUInteger options, id *err) {
    BOOL ok = YES;
    if (WCR_orig_setCategory4) ok = WCR_orig_setCategory4(self, cmd, category, mode, options, err);
    else {
        IMP o = WCRLookupOrig(self, cmd);
        if (o) ok = ((BOOL(*)(id, SEL, id, id, NSUInteger, id *))o)(self, cmd, category, mode, options, err);
    }
    @try {
        NSString *cat = [category isKindOfClass:[NSString class]] ? (NSString *)category : [category description];
        NSString *md = [mode isKindOfClass:[NSString class]] ? (NSString *)mode : [mode description];
        WCRNoteCallAudioMaybeStarted(@"setCategory:mode:", cat, md);
        WCRLog("AVAudioSession setCategory:%@ mode:%@", cat, md);
    } @catch (__unused NSException *e) {}
    return ok;
}

static BOOL (*WCR_orig_setActive)(id, SEL, BOOL, id *) = NULL;
static BOOL WCR_repl_setActive(id self, SEL cmd, BOOL active, id *err) {
    BOOL ok = YES;
    if (WCR_orig_setActive) ok = WCR_orig_setActive(self, cmd, active, err);
    else {
        IMP o = WCRLookupOrig(self, cmd);
        if (o) ok = ((BOOL(*)(id, SEL, BOOL, id *))o)(self, cmd, active, err);
    }
    @try {
        if (active) {
            NSString *cat = nil; NSString *mode = nil;
            @try {
                AVAudioSession *s = [AVAudioSession sharedInstance];
                cat = s.category; mode = s.mode;
            } @catch (__unused NSException *e) {}
            WCRNoteCallAudioMaybeStarted(@"setActive:YES", cat, mode);
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WCRNoteCallAudioMaybeEnded(@"setActive:NO");
            });
        }
    } @catch (__unused NSException *e) {}
    return ok;
}

static BOOL (*WCR_orig_setMode)(id, SEL, id, id *) = NULL;
static BOOL WCR_repl_setMode(id self, SEL cmd, id mode, id *err) {
    BOOL ok = YES;
    if (WCR_orig_setMode) ok = WCR_orig_setMode(self, cmd, mode, err);
    else {
        IMP o = WCRLookupOrig(self, cmd);
        if (o) ok = ((BOOL(*)(id, SEL, id, id *))o)(self, cmd, mode, err);
    }
    @try {
        NSString *md = [mode isKindOfClass:[NSString class]] ? (NSString *)mode : [mode description];
        NSString *cat = nil;
        @try { cat = [AVAudioSession sharedInstance].category; } @catch (__unused NSException *e) {}
        WCRNoteCallAudioMaybeStarted(@"setMode", cat, md);
        WCRLog("AVAudioSession setMode:%@", md);
    } @catch (__unused NSException *e) {}
    return ok;
}

static void WCRInstallAVAudioSessionHooks(void) {
    Class cls = NSClassFromString(@"AVAudioSession");
    if (!cls) return;
    int n = 0;
    SEL s1 = @selector(setCategory:error:);
    if (class_getInstanceMethod(cls, s1)) {
        Method m = class_getInstanceMethod(cls, s1);
        if (m) {
            char ret[8] = {0}; method_getReturnType(m, ret, sizeof(ret));
            if (ret[0] == 'B' || ret[0] == 'c') {
                BOOL newly = WCRHookInstance(cls, s1, (IMP)WCR_repl_setCategory1);
                NSValue *v = WCROrigMap()[WCRHookKey(cls, s1)];
                if (v) WCR_orig_setCategory1 = (BOOL(*)(id,SEL,id,id*))v.pointerValue;
                if (newly) n++;
            }
        }
    }
    SEL s4 = @selector(setCategory:mode:options:error:);
    if (class_getInstanceMethod(cls, s4)) {
        Method m = class_getInstanceMethod(cls, s4);
        if (m) {
            char ret[8] = {0}; method_getReturnType(m, ret, sizeof(ret));
            if (ret[0] == 'B' || ret[0] == 'c') {
                BOOL newly = WCRHookInstance(cls, s4, (IMP)WCR_repl_setCategory4);
                NSValue *v = WCROrigMap()[WCRHookKey(cls, s4)];
                if (v) WCR_orig_setCategory4 = (BOOL(*)(id,SEL,id,id,NSUInteger,id*))v.pointerValue;
                if (newly) n++;
            }
        }
    }
    SEL sa = @selector(setActive:error:);
    if (class_getInstanceMethod(cls, sa)) {
        Method m = class_getInstanceMethod(cls, sa);
        if (m) {
            char ret[8] = {0}; method_getReturnType(m, ret, sizeof(ret));
            if (ret[0] == 'B' || ret[0] == 'c') {
                BOOL newly = WCRHookInstance(cls, sa, (IMP)WCR_repl_setActive);
                NSValue *v = WCROrigMap()[WCRHookKey(cls, sa)];
                if (v) WCR_orig_setActive = (BOOL(*)(id,SEL,BOOL,id*))v.pointerValue;
                if (newly) n++;
            }
        }
    }
    SEL sm = @selector(setMode:error:);
    if (class_getInstanceMethod(cls, sm)) {
        Method m = class_getInstanceMethod(cls, sm);
        if (m) {
            char ret[8] = {0}; method_getReturnType(m, ret, sizeof(ret));
            if (ret[0] == 'B' || ret[0] == 'c') {
                BOOL newly = WCRHookInstance(cls, sm, (IMP)WCR_repl_setMode);
                NSValue *v = WCROrigMap()[WCRHookKey(cls, sm)];
                if (v) WCR_orig_setMode = (BOOL(*)(id,SEL,id,id*))v.pointerValue;
                if (newly) n++;
            }
        }
    }
    // Also hook setActive:withOptions:error: used by some VoIP stacks.
    SEL sa2 = NSSelectorFromString(@"setActive:withOptions:error:");
    if (sa2 && class_getInstanceMethod(cls, sa2)) {
        // reuse setActive IMP shape carefully via probe-less direct trampoline not available;
        // setActive:error: + setCategory cover most call paths.
    }
    if (n > 0) {
        atomic_fetch_add(&gWCRLifecycleHooksInstalled, n);
        WCRInfo("AVAudioSession hooks newly installed: %d", n);
    } else if (WCROrigMap()[WCRHookKey(cls, s1)] || WCROrigMap()[WCRHookKey(cls, sa)]) {
        WCRLog("AVAudioSession hooks already present");
    } else {
        WCRInfo("AVAudioSession hooks FAILED (class=%p)", cls);
    }
}

static void WCRRescanAllHooks(const char *why) {
    static atomic_int busy = 0;
    static double last = 0;
    double now = [NSDate date].timeIntervalSinceReferenceDate;
    BOOL force = (why && (strstr(why, "manual") || strstr(why, "call-start") || strstr(why, "constructor")));
    if (!force && (now - last) < 0.75) return;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&busy, &expected, 1)) {
        // Do not drop forced scans (constructor/call-start/manual).
        if (force) {
            const char *whyCopy = why ? why : "retry";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WCRRescanAllHooks(whyCopy);
            });
        }
        return;
    }
    last = now;
    @try {
        WCRInfo("rescan hooks (%s) begin life~%ld audio~%ld AU=%d total=%lu",
                why ?: "?",
                (long)WCRLifecycleHookCount(),
                (long)WCRAudioHookCount(),
                (int)atomic_load(&gWCRAudioUnitHooksInstalled),
                (unsigned long)WCRHookedKeys().count);
        WCRInstallLifecycle();
        WCRInstallAVAudioSessionHooks();
        WCRInstallCallViewControllerHooks();
        WCRInstallDiscoveredAudioHooks();
        WCRInstallManualAudioHooks();
        WCRAutoScanAudioHooks();
        WCRInstallProbeAudioHooks();
        WCRInstallAudioUnitHooks();
        BOOL recording = NO;
        @try { recording = [[WCRSessionManager shared] isRecording]; } @catch (__unused NSException *e) {}
        if (WCRVerboseFlag() || recording || (why && strstr(why, "call-start"))) {
            WCRAggressiveAudioScan();
        }
        if (recording || (why && strstr(why, "call-start"))) {
            @try { WCRDumpAudioCandidates(); } @catch (__unused NSException *e) {}
        }
        WCRInfo("rescan hooks (%s) end life=%ld audio~%ld AU=%d probe=%d/%d total=%lu",
                why ?: "?",
                (long)WCRLifecycleHookCount(),
                (long)WCRAudioHookCount(),
                (int)atomic_load(&gWCRAudioUnitHooksInstalled),
                (int)atomic_load(&gWCRProbeHooksInstalled),
                (int)atomic_load(&gWCRProbeHits),
                (unsigned long)WCRHookedKeys().count);
    } @catch (NSException *e) {
        WCRInfo("rescan exception: %@", e);
    }
    atomic_store(&busy, 0);
}

static void WCRDyldAddImageCallback(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    static atomic_int pending = 0;
    if (atomic_exchange(&pending, 1)) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        atomic_store(&pending, 0);
        if (!WCREnabled()) return;
        @try {
            WCRRescanAllHooks("dyld-add-image");
        } @catch (__unused NSException *e) {}
    });
}

static void WCRRegisterDyldObserver(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _dyld_register_func_for_add_image(WCRDyldAddImageCallback);
        WCRInfo("dyld add-image observer registered");
    });
}

static void WCRPollCallState(void) {
    if (!WCREnabled()) return;
    static BOOL wasInCall = NO;
    BOOL inCall = NO;
    @try { inCall = WCRIsLikelyInCallUI(); } @catch (__unused NSException *e) { inCall = NO; }
    BOOL audioCall = NO;
    @try { audioCall = WCRLooksLikeActiveCallAudio(); } @catch (__unused NSException *e) {}
    BOOL recording = NO;
    @try { recording = [[WCRSessionManager shared] isRecording]; } @catch (__unused NSException *e) {}

    if ((inCall || audioCall) && !recording) {
        // Incoming answer often only shows VoIP UI + PlayAndRecord, without known lifecycle selectors.
        WCRMaybeBeginFromAudioTap(inCall ? "poll-call-ui" : "poll-call-audio");
        if (![[WCRSessionManager shared] isRecording]) {
            @try {
                WCROnCallMaybeStarted();
                NSString *hint = WCRGetLastContactName() ?: WCRGetLastContactHint() ?: WCRScrapeCallUIContactName();
                if (hint.length == 0 || WCRLooksLikeBadDisplayName(hint)) hint = @"\u901a\u8bdd";
                // Force-open session for BOTH call UI and active PlayAndRecord/VoiceChat audio.
                NSString *reason = inCall ? @"poll-call-ui-force" : @"poll-call-audio-force";
                [[WCRSessionManager shared] beginWithReason:reason
                                               contactHint:hint
                                                sampleRate:WCRPreferredSampleRate()];
                WCRInfo("force-begin from poll (%@ inCall=%d audio=%d)", reason, inCall?1:0, audioCall?1:0);
            } @catch (__unused NSException *e) {}
        }
    } else if (recording && wasInCall && !inCall && !audioCall) {
        WCRInfo("poll: left call ui while recording");
    }
    wasInCall = inCall;
}

static void WCRStartCallPoller(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        if (!timer) return;
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                                  (uint64_t)(0.8 * NSEC_PER_SEC),
                                  (uint64_t)(0.15 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(timer, ^{
            @try { WCRPollCallState(); } @catch (__unused NSException *e) {}
        });
        dispatch_resume(timer);
        WCRInfo("call-state poller started (0.8s)");
    });
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
            if (WCREnabled()) {
                @try { WCRRescanAllHooks("become-active"); } @catch (__unused NSException *e) {}
            }
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
            @try {
                NSNumber *type = n.userInfo[AVAudioSessionInterruptionTypeKey];
                if (type && type.unsignedIntegerValue == AVAudioSessionInterruptionTypeEnded) {
                    // Call audio stack often flushes on interruption end; re-arm hooks.
                    if (WCREnabled()) WCRRescanAllHooks("audio-interruption-end");
                }
            } @catch (__unused NSException *e) {}
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification *n) {
            @try {
                if (!WCREnabled()) return;
                if ([[WCRSessionManager shared] isRecording]) {
                    WCRRescanAllHooks("route-change");
                }
            } @catch (__unused NSException *e) {}
        }];
    });
}

__attribute__((constructor))
static void WCallRecorderInit(void) {
    @autoreleasepool {
        WCRInfo("free rewrite for WeChat 8.0.71 loaded (v%@, enabled=%d, no auth)", kWCRPluginVersion, WCREnabled());
        WCRRegisterDyldObserver();
        dispatch_async(dispatch_get_main_queue(), ^{
            WCRInstallUIEntries();
            WCRObserveLifecycle();
            WCRStartCallPoller();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) { WCRInfo("disabled WCR.Enabled=0"); return; }
            @try {
                WCRInstallUIEntries();
                WCRRescanAllHooks("constructor+1s");
                WCREnsureFloatingBall();
                if (!WCRBool(kWCRPrivateKey, NO)) {
                    WCRShowToast([NSString stringWithFormat:@"WCallRecorder \u5df2\u52a0\u8f7d v%@\n\u70b9\u53f3\u4e0b\u89d2\u84dd\u8272\u60ac\u6d6e\u7403\u6253\u5f00", kWCRPluginVersion]);
                }
                WCRInfo("ready for 8.0.71 => %@ (life=%ld audio~%ld AU=%d)",
                        [[WCRSessionManager shared] rootDir],
                        (long)WCRLifecycleHookCount(),
                        (long)WCRAudioHookCount(),
                        (int)atomic_load(&gWCRAudioUnitHooksInstalled));
            } @catch (NSException *e) {
                WCRInfo("install exception: %@", e);
            }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) return;
            @try {
                WCRInstallUIEntries();
                WCRRescanAllHooks("constructor+3s");
                WCREnsureFloatingBall();
            } @catch (__unused NSException *e) {}
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) return;
            @try {
                WCRTryRegisterPlugin();
                WCRRescanAllHooks("constructor+8s");
                WCREnsureFloatingBall();
            } @catch (__unused NSException *e) {}
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!WCREnabled()) return;
            @try { WCRRescanAllHooks("constructor+20s"); } @catch (__unused NSException *e) {}
        });
    }
}
