//
// Douyin.dylib - unlock video/image save for Douyin (Aweme)
// Bundle: com.ss.iphone.ugc.Aweme | executable: Aweme | analyzed: 38.7.0
//
// v1.6:
//   - Prefer original/high quality: downloadAddr/bitRate > adaptive play stream
//   - Stronger res/bitrate scoring; export uses Passthrough/Highest first (not Medium)
//   - Still current-item only + safe boot
//
// v1.5:
//   - Current-item only: most-visible feed cell + active player (fix next-video save)
//   - Still SAFE boot (no global JSON/UserDefaults/toast hooks)
//   - Keep Photos-first save + no-wm URL variants
//
// v1.4:
//   - SAFE boot: NO JSON/UserDefaults/toast/i18n hooks (they crash Aweme 38.x)
//   - Only floating save UI + download pipeline; optional minimal AWE gate patch
//   - Keep v1.3 Photos-first save + no-wm URL variants
//
// v1.3:
//   - Stability: no full-class scan hooks; safer KVC; direct Photos write first
//   - No-watermark prefer: downloadAddr / play (not playwm) + URL rewrite
//   - Cache scan off main / lighter playable probe (avoid watchdog crash)
//
// v1.2:
//   - Multi-URL video try; strict content check (no image/HTML as video)
//   - Photos verifies localIdentifier + mediaType==Video
//   - Collect aweme models from cells; deeper local cache scan
//
// v1.1:
//   - Video-first: never treat feed cover as success video save
//   - Stronger player/model URL collect (TTVideoEngine/IES keys + AVPlayerLayer)
//   - Douyin CDN without .mp4 still counted as video; heavy penalty for cover/byteimg
//   - Photos write verifies localIdentifier; cookie-aware download
//
// v1:
//   - Based on Xiaohongshu v1 save pipeline (Photos + AV re-export)
//   - Gate unlock: preventDownload / allowDownload / canDownload
//   - JSON rewrite: prevent_download / allow_download / can_download
//   - Fallback: floating down-arrow + two-finger long press
//     collect downloadAddr / playAddr / AWEURLModel urlList
//     prefer non-watermark download URL; skip m3u8
//   - Light startup: known-class only at load; one deferred class scan
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <pthread.h>
#import <unistd.h>

static const BOOL kVerbose = NO;
#define LOG(fmt, ...) do { if (kVerbose) NSLog(@"[DouyinSave] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - target

static BOOL DYIsTarget(void) {
    static int cached = -1;
    if (cached >= 0) return cached != 0;
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSString *exe = [[NSBundle mainBundle].executablePath lastPathComponent] ?: @"";
    cached = ([bid isEqualToString:@"com.ss.iphone.ugc.Aweme"] ||
              [exe isEqualToString:@"Aweme"]) ? 1 : 0;
    return cached != 0;
}

#pragma mark - bool / void stubs

static BOOL DY_retNO(id s, SEL c) { (void)s; (void)c; return NO; }
static BOOL DY_retYES(id s, SEL c) { (void)s; (void)c; return YES; }
static id   DY_retYesObj(id s, SEL c) { (void)s; (void)c; return @YES; }
static id   DY_retNoObj(id s, SEL c) { (void)s; (void)c; return @NO; }
static void DY_void0(id s, SEL c) { (void)s; (void)c; }
static void DY_setBoolDrop(id s, SEL c, BOOL v) { (void)s; (void)c; (void)v; }

static void DYPatchBool(Class cls, const char *selName, BOOL value) {
    // v1.4: ONLY true BOOL/char returns. Never patch '@' methods — returning @YES
    // for a method that actually returns a model/object crashes Aweme later.
    if (!cls || !selName) return;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (method_getNumberOfArguments(m) != 2) return; // instance getter only
    const char *t = method_getTypeEncoding(m);
    if (!t) return;
    if (t[0] == 'B' || t[0] == 'c') {
        method_setImplementation(m, value ? (IMP)DY_retYES : (IMP)DY_retNO);
        LOG(@"%s -%s => %d", class_getName(cls), selName, (int)value);
    }
    // deliberately ignore '@' / other encodings
}

static void DYPatchVoid(Class cls, const char *selName) {
    if (!cls || !selName) return;
    Method m = class_getInstanceMethod(cls, sel_registerName(selName));
    if (!m) return;
    if (method_getNumberOfArguments(m) == 2) {
        method_setImplementation(m, (IMP)DY_void0);
        LOG(@"nop %s -%s", class_getName(cls), selName);
    }
}

static void DYPatchSetterDrop(Class cls, const char *selName) {
    if (!cls || !selName) return;
    Method m = class_getInstanceMethod(cls, sel_registerName(selName));
    if (!m) return;
    // only (id,SEL,BOOL) style setters
    if (method_getNumberOfArguments(m) != 3) return;
    const char *t = method_getTypeEncoding(m);
    if (!t || t[0] != 'v') return;
    // look for BOOL/char arg roughly: encoding like v@:B or v@:c
    if (!(strstr(t, "B") || strstr(t, "c"))) return;
    method_setImplementation(m, (IMP)DY_setBoolDrop);
}

static BOOL DYNameLooksSaveProvider(const char *name) {
    if (!name) return NO;
    return strstr(name, "Download") ||
           strstr(name, "AwemeModel") ||
           strstr(name, "VideoModel") ||
           strstr(name, "PreventDownload") ||
           strstr(name, "DownloadPermission") ||
           strstr(name, "DownloadEntrance") ||
           strstr(name, "VideoDownloader");
}

static void DYPatchKnownClass(Class cls);

static void DYForceConfigObject(id cfg) {
    if (!cfg) return;
    DYPatchKnownClass(object_getClass(cfg));
    @try {
        SEL s = sel_registerName("setDisableSave:");
        if ([cfg respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(cfg, s, NO);
        }
    } @catch (__unused NSException *e) {}
    @try {
        SEL s = sel_registerName("setForbidCopy:");
        if ([cfg respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(cfg, s, NO);
        }
    } @catch (__unused NSException *e) {}
    @try {
        SEL s = sel_registerName("setDisableWatermark:");
        if ([cfg respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(cfg, s, YES);
        }
    } @catch (__unused NSException *e) {}
    @try {
        if ([cfg respondsToSelector:@selector(setValue:forKey:)]) {
            [cfg setValue:@NO forKey:@"disableSave"];
            [cfg setValue:@NO forKey:@"disable_save"];
            [cfg setValue:@NO forKey:@"forbidCopy"];
            [cfg setValue:@YES forKey:@"disableWatermark"];
            [cfg setValue:@YES forKey:@"shareImageSaveEnable"];
            [cfg setValue:@YES forKey:@"share_image_save_enable"];
        }
    } @catch (__unused NSException *e) {}
}

static void DYPatchKnownClass(Class cls) {
    if (!cls) return;

    // Douyin / Aweme download gates
    DYPatchBool(cls, "preventDownload", NO);
    DYPatchBool(cls, "hasPreventDownload", NO);
    DYPatchBool(cls, "isPreventDownload", NO);
    DYPatchBool(cls, "shouldPreventDownload", NO);
    DYPatchBool(cls, "isControlledByPreventDownload", NO);
    DYPatchBool(cls, "isControlledByPreventDownloadType", NO);
    DYPatchBool(cls, "allowDownload", YES);
    DYPatchBool(cls, "canDownload", YES);
    DYPatchBool(cls, "canDownloadApp", YES);
    DYPatchBool(cls, "p_allowDownload", YES);
    DYPatchBool(cls, "shouldShowDownload", YES);
    DYPatchBool(cls, "isDownloadEnabled", YES);
    DYPatchBool(cls, "downloadEnabled", YES);
    DYPatchBool(cls, "showDownload", YES);
    DYPatchBool(cls, "enableDownload", YES);
    DYPatchBool(cls, "canShowDownload", YES);
    DYPatchSetterDrop(cls, "setPreventDownload:");
    DYPatchSetterDrop(cls, "setPreventDownloadType:");
    DYPatchSetterDrop(cls, "setAllowDownload:");
    DYPatchSetterDrop(cls, "setCanDownload:");

    // disableSave -> allow
    DYPatchBool(cls, "disableSave", NO);
    DYPatchBool(cls, "isDisableSave", NO);
    DYPatchBool(cls, "forbidCopy", NO);
    DYPatchBool(cls, "disableCopy", NO);
    DYPatchBool(cls, "disableCopyAction", NO);
    // author download switch
    DYPatchBool(cls, "disableWatermark", YES);
    DYPatchBool(cls, "disableWatermarkWhenSavingAlbum", YES);
    DYPatchSetterDrop(cls, "setDisableSave:");
    DYPatchSetterDrop(cls, "setForbidCopy:");
    DYPatchSetterDrop(cls, "setDisableCopy:");

    // watermark-related flags if present
    DYPatchBool(cls, "hitUserNoteDownloadSwitch", NO);
    DYPatchBool(cls, "hitRacingUserNoteDownloadSwitch", NO);
    DYPatchBool(cls, "userNoteDownloadSwitch", YES);
    DYPatchBool(cls, "isFlowDownloadSwitchOn", YES);
    DYPatchBool(cls, "notAllowDownloadMyVideos", NO);
    DYPatchBool(cls, "notAllowDownloadMyVideosSwitchOn", NO);
    DYPatchBool(cls, "allowDownload", YES);
    DYPatchBool(cls, "shareImageSaveEnable", YES);
    DYPatchBool(cls, "shareVideoSaveEnable", YES);
    DYPatchBool(cls, "userVideoDownloadSwitch", YES);
    DYPatchBool(cls, "videoDownloadSwitch", YES);
    DYPatchBool(cls, "mobileDownloadSwitch", YES);
    DYPatchBool(cls, "enableSave", YES);
    DYPatchBool(cls, "saveEnable", YES);
    DYPatchBool(cls, "hasSaveNotAllowDownloadMyVideosKey", NO);
    DYPatchBool(cls, "isShowedAdvanceOptionNoteDownloadTips", YES);

    // v1.4: do NOT patch generic enable/isAvailable/isEnabled — breaks AWE download UI/modules
    // keep only explicit download permission getters above + safe void toasts

    DYPatchVoid(cls, "checkShowCloseNoteDownloadSwitchToast");
    DYPatchVoid(cls, "showCloseNoteDownloadSwitchToast");
    DYPatchVoid(cls, "showDownloadPermissionToast");
    // setters skipped in v1.4 safe path (called only if encoding matches via DYPatchSetterDrop)
    DYPatchSetterDrop(cls, "setHitRacingUserNoteDownloadSwitch:");
}

#pragma mark - once class hooks

static void DYInstallClassHooksKnown(void) {
    const char *known[] = {
        "AWEAwemeModel",
        "AWEVideoModel",
        "AWEAwemeStatusModel",
        "AWEDownloadPermissionItem",
        "AWEDownloadSettingUtil",
        "AWEDownloadEntranceHelper",
        "AWEAwemeDetailNaviBarDownloadElement",
        "AWEAwemeVideoDownloader",
        "AWEDownloadShareChannel",
        "AWEDYDownloadShareChannel",
        "AWEDYSimpleDownloadShareChannel",
        "AWEChallengeDownloadComponent",
        "AWEChallengeDownloadInfoModel",
        "AWEConsumerDownloadBlockList",
        "AWEDuetDownloadAuthorityTextSettingsModel",
        "AWEImageAlbumImageModel",
        NULL
    };
    for (const char **p = known; *p; p++) {
        DYPatchKnownClass(objc_getClass(*p));
    }
}

static void DYScanClassHooks(void) {
    // deferred only - never call from constructor
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;

    unsigned patched = 0;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = list[i];
        if (class_getInstanceMethod(cls, sel_registerName("preventDownload")) ||
            class_getInstanceMethod(cls, sel_registerName("allowDownload")) ||
            class_getInstanceMethod(cls, sel_registerName("canDownload")) ||
            class_getInstanceMethod(cls, sel_registerName("hasPreventDownload")) ||
            class_getInstanceMethod(cls, sel_registerName("isControlledByPreventDownload")) ||
            class_getInstanceMethod(cls, sel_registerName("shouldShowDownload")) ||
            class_getInstanceMethod(cls, sel_registerName("isDownloadEnabled")) ||
            class_getInstanceMethod(cls, sel_registerName("disableSave")) ||
            class_getInstanceMethod(cls, sel_registerName("shareVideoSaveEnable"))) {
            DYPatchKnownClass(cls);
            if (++patched > 80) break;
        }
    }
    free(list);
    LOG(@"class scan done, patched=%u / %u", patched, n);
}

static void DYInstallClassHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DYInstallClassHooksKnown();
        LOG(@"class hooks known-only (v8)");
    });
}

#pragma mark - object tree rewrite (NSJSONSerialization path)

static BOOL DYLooksTruthy(id v) {
    if (!v || v == [NSNull null]) return NO;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        return [s isEqualToString:@"1"] || [s isEqualToString:@"true"] || [s isEqualToString:@"yes"];
    }
    return NO;
}

static BOOL DYLooksFalsey(id v) {
    if (!v || v == [NSNull null]) return YES;
    if ([v isKindOfClass:[NSNumber class]]) return ![(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        return [s isEqualToString:@"0"] || [s isEqualToString:@"false"] || [s isEqualToString:@"no"] || s.length == 0;
    }
    return NO;
}

static BOOL DYPatchObjectTree(id obj, NSInteger depth) {
    if (!obj || depth > 8) return NO;
    BOOL changed = NO;

    if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *md = (NSMutableDictionary *)obj;
        static NSSet<NSString *> *forceFalse;
        static NSSet<NSString *> *forceTrue;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            forceFalse = [NSSet setWithArray:@[
                @"prevent_download", @"preventDownload",
                @"prevent_download_type", @"preventDownloadType",
                @"has_prevent_download", @"hasPreventDownload",
                @"disable_save", @"disableSave",
                @"forbid_copy", @"forbidCopy",
                @"notAllowDownloadMyVideos", @"not_allow_download_my_videos",
            ]];
            forceTrue = [NSSet setWithArray:@[
                @"allow_download", @"allowDownload",
                @"can_download", @"canDownload",
                @"can_download_app", @"canDownloadApp",
                @"shareImageSaveEnable", @"share_image_save_enable",
                @"shareVideoSaveEnable", @"share_video_save_enable",
                @"enableSave", @"saveEnable",
                @"download_enabled", @"downloadEnabled",
                @"is_download_enabled", @"isDownloadEnabled",
                @"should_show_download", @"shouldShowDownload",
            ]];
        });

        NSArray *keys = md.allKeys;
        for (id key in keys) {
            if (![key isKindOfClass:[NSString class]]) continue;
            NSString *k = (NSString *)key;
            id val = md[k];

            if ([forceFalse containsObject:k] && DYLooksTruthy(val)) {
                md[k] = @NO;
                changed = YES;
            } else if ([forceTrue containsObject:k] && DYLooksFalsey(val)) {
                md[k] = @YES;
                changed = YES;
            } else if ([val isKindOfClass:[NSDictionary class]] ||
                       [val isKindOfClass:[NSArray class]]) {
                if ([val isKindOfClass:[NSDictionary class]] &&
                    ![val isKindOfClass:[NSMutableDictionary class]]) {
                    NSMutableDictionary *child = [val mutableCopy];
                    if (DYPatchObjectTree(child, depth + 1)) {
                        md[k] = child;
                        changed = YES;
                    }
                } else if ([val isKindOfClass:[NSArray class]] &&
                           ![val isKindOfClass:[NSMutableArray class]]) {
                    NSMutableArray *child = [val mutableCopy];
                    if (DYPatchObjectTree(child, depth + 1)) {
                        md[k] = child;
                        changed = YES;
                    }
                } else {
                    if (DYPatchObjectTree(val, depth + 1)) changed = YES;
                }
            }
        }
        return changed;
    }

    if ([obj isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *ma = (NSMutableArray *)obj;
        for (NSUInteger i = 0; i < ma.count; i++) {
            id val = ma[i];
            if ([val isKindOfClass:[NSDictionary class]] &&
                ![val isKindOfClass:[NSMutableDictionary class]]) {
                NSMutableDictionary *child = [val mutableCopy];
                if (DYPatchObjectTree(child, depth + 1)) {
                    ma[i] = child;
                    changed = YES;
                }
            } else if ([val isKindOfClass:[NSArray class]] &&
                       ![val isKindOfClass:[NSMutableArray class]]) {
                NSMutableArray *child = [val mutableCopy];
                if (DYPatchObjectTree(child, depth + 1)) {
                    ma[i] = child;
                    changed = YES;
                }
            } else if ([val isKindOfClass:[NSMutableDictionary class]] ||
                       [val isKindOfClass:[NSMutableArray class]]) {
                if (DYPatchObjectTree(val, depth + 1)) changed = YES;
            }
        }
        return changed;
    }

    return NO;
}

static id DYMaybePatchJSONObject(id obj) {
    if (!obj) return obj;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *md = [obj mutableCopy];
        if (DYPatchObjectTree(md, 0)) {
            LOG(@"json object dict patched");
            return md;
        }
        return obj;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *ma = [obj mutableCopy];
        if (DYPatchObjectTree(ma, 0)) {
            LOG(@"json object array patched");
            return ma;
        }
        return obj;
    }
    return obj;
}

#pragma mark - raw JSON bytes patch (fallback)

static BOOL DYDataLooksRelated(NSData *data) {
    if (data.length < 32 || data.length > 8 * 1024 * 1024) return NO;
    static NSArray<NSData *> *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[
            [@"prevent_download" dataUsingEncoding:NSUTF8StringEncoding],
            [@"preventDownload" dataUsingEncoding:NSUTF8StringEncoding],
            [@"prevent_download_type" dataUsingEncoding:NSUTF8StringEncoding],
            [@"allow_download" dataUsingEncoding:NSUTF8StringEncoding],
            [@"allowDownload" dataUsingEncoding:NSUTF8StringEncoding],
            [@"can_download" dataUsingEncoding:NSUTF8StringEncoding],
            [@"canDownload" dataUsingEncoding:NSUTF8StringEncoding],
            [@"download_addr" dataUsingEncoding:NSUTF8StringEncoding],
            [@"play_addr" dataUsingEncoding:NSUTF8StringEncoding],
            [@"disable_save" dataUsingEncoding:NSUTF8StringEncoding],
            [@"shareVideoSaveEnable" dataUsingEncoding:NSUTF8StringEncoding],
        ];
    });
    NSRange full = NSMakeRange(0, data.length);
    for (NSData *n in needles) {
        if ([data rangeOfData:n options:0 range:full].location != NSNotFound) return YES;
    }
    return NO;
}

static NSData *DYPatchNoteJSONBytes(NSData *data) {
    if (!DYDataLooksRelated(data)) return data;

    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) return data;

    NSArray<NSArray<NSString *> *> *pairs = @[
        @[@"\"disable_save\":true",  @"\"disable_save\":false"],
        @[@"\"disable_save\": true", @"\"disable_save\": false"],
        @[@"\"disableSave\":true",   @"\"disableSave\":false"],
        @[@"\"disableSave\": true",  @"\"disableSave\": false"],
        @[@"\"disable_save\":1",     @"\"disable_save\":0"],
        @[@"\"disableSave\":1",      @"\"disableSave\":0"],

        @[@"\"forbid_copy\":true",   @"\"forbid_copy\":false"],
        @[@"\"forbidCopy\":true",    @"\"forbidCopy\":false"],
        @[@"\"forbidCopy\": true",   @"\"forbidCopy\": false"],

        @[@"\"hitUserNoteDownloadSwitch\":true",  @"\"hitUserNoteDownloadSwitch\":false"],
        @[@"\"hitUserNoteDownloadSwitch\": true", @"\"hitUserNoteDownloadSwitch\": false"],
        @[@"\"hitRacingUserNoteDownloadSwitch\":true",  @"\"hitRacingUserNoteDownloadSwitch\":false"],
        @[@"\"hitRacingUserNoteDownloadSwitch\": true", @"\"hitRacingUserNoteDownloadSwitch\": false"],

        @[@"\"notAllowDownloadMyVideos\":true",  @"\"notAllowDownloadMyVideos\":false"],
        @[@"\"notAllowDownloadMyVideos\": true", @"\"notAllowDownloadMyVideos\": false"],
        @[@"\"not_allow_download_my_videos\":true", @"\"not_allow_download_my_videos\":false"],
        @[@"\"notAllowDownloadMyVideos\":1", @"\"notAllowDownloadMyVideos\":0"],

        @[@"\"userNoteDownloadSwitch\":false",  @"\"userNoteDownloadSwitch\":true"],
        @[@"\"userNoteDownloadSwitch\": false", @"\"userNoteDownloadSwitch\": true"],
        @[@"\"user_note_download_switch\":false", @"\"user_note_download_switch\":true"],
        @[@"\"user_video_download_switch\":false", @"\"user_video_download_switch\":true"],
        @[@"\"user_video_download_switch\": false", @"\"user_video_download_switch\": true"],
        @[@"\"userVideoDownloadSwitch\":false", @"\"userVideoDownloadSwitch\":true"],
        @[@"\"isFlowDownloadSwitchOn\":false", @"\"isFlowDownloadSwitchOn\":true"],
        @[@"\"shareImageSaveEnable\":false", @"\"shareImageSaveEnable\":true"],
        @[@"\"share_image_save_enable\":false", @"\"share_image_save_enable\":true"],
        @[@"\"shareVideoSaveEnable\":false", @"\"shareVideoSaveEnable\":true"],
        @[@"\"allowDownload\":false", @"\"allowDownload\":true"],
        @[@"\"allow_download\":false", @"\"allow_download\":true"],
        @[@"\"mobile_download_switch\":false", @"\"mobile_download_switch\":true"],
        @[@"\"disable_watermark\":false", @"\"disable_watermark\":true"],
        @[@"\"disableWatermark\":false", @"\"disableWatermark\":true"],
        @[@"\"enableSave\":false", @"\"enableSave\":true"],
        @[@"\"saveEnable\":false", @"\"saveEnable\":true"],
        @[@"\"notAllowDownloadMyVideosSwitchOn\":true", @"\"notAllowDownloadMyVideosSwitchOn\":false"],
        @[@"\"enable_save_photo_default\":false", @"\"enable_save_photo_default\":true"],
    ];

    NSString *out = s;
    BOOL changed = NO;
    for (NSArray *p in pairs) {
        if ([out containsString:p[0]]) {
            out = [out stringByReplacingOccurrencesOfString:p[0] withString:p[1]];
            changed = YES;
        }
    }
    if (!changed) return data;
    NSData *nd = [out dataUsingEncoding:NSUTF8StringEncoding];
    LOG(@"json bytes patched %lu -> %lu", (unsigned long)data.length, (unsigned long)nd.length);
    return nd ?: data;
}

#pragma mark - NSJSONSerialization hook

static id (*orig_JSONObjectWithData)(id, SEL, NSData *, NSJSONReadingOptions, NSError **);

static id hook_JSONObjectWithData(id self, SEL _cmd, NSData *data, NSJSONReadingOptions opt, NSError **err) {
    // hot path: never force mutable / rewrite on every JSON parse
    if (!data.length || data.length > 512 * 1024 || !DYDataLooksRelated(data)) {
        return orig_JSONObjectWithData ? orig_JSONObjectWithData(self, _cmd, data, opt, err) : nil;
    }
    NSData *use = data;
    @try { use = DYPatchNoteJSONBytes(data); }
    @catch (__unused NSException *e) { use = data; }
    NSJSONReadingOptions o2 = opt | NSJSONReadingMutableContainers;
    id obj = orig_JSONObjectWithData ? orig_JSONObjectWithData(self, _cmd, use, o2, err) : nil;
    if (!obj) return obj;
    @try {
        id patched = DYMaybePatchJSONObject(obj);
        return patched ?: obj;
    } @catch (__unused NSException *e) {
        return obj;
    }
}

static void DYInstallJSONHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("NSJSONSerialization");
        if (!cls) return;
        SEL sel = @selector(JSONObjectWithData:options:error:);
        Method m = class_getClassMethod(cls, sel);
        if (!m) return;
        orig_JSONObjectWithData = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_JSONObjectWithData);
        LOG(@"NSJSONSerialization hooked");
    });
}

#pragma mark - NSURLSession dataTask completion (secondary)

typedef void (^DYDataCompletion)(NSData *, NSURLResponse *, NSError *);
static id (*orig_dataTask)(id, SEL, NSURLRequest *, DYDataCompletion);

static id hook_dataTask(id self, SEL _cmd, NSURLRequest *req, DYDataCompletion completion) {
    if (!completion) return orig_dataTask(self, _cmd, req, completion);
    DYDataCompletion wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSData *patched = data;
        if (!err && data.length) {
            @try { patched = DYPatchNoteJSONBytes(data); }
            @catch (__unused NSException *e) { patched = data; }
        }
        completion(patched, resp, err);
    };
    return orig_dataTask(self, _cmd, req, wrapped);
}

static void DYInstallSessionHook(void) {
    // v8: disabled - wrapping every dataTask stalls feed/home networking.
    (void)hook_dataTask;
    (void)orig_dataTask;
    LOG(@"NSURLSession hook skipped (v8)");
}

#pragma mark - mediaSaveConfig getter / setter

static const void *kDYOrigGetKey = &kDYOrigGetKey;
static const void *kDYOrigSetKey = &kDYOrigSetKey;

static IMP DYLoadOrigIMP(Class cls, const void *key) {
    if (!cls) return NULL;
    NSValue *v = objc_getAssociatedObject((id)cls, key);
    return v ? (IMP)v.pointerValue : NULL;
}

static void DYStoreOrigIMP(Class cls, const void *key, IMP imp) {
    if (!cls || !imp) return;
    objc_setAssociatedObject((id)cls, key, [NSValue valueWithPointer:imp], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id hook_msc_get(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    IMP orig = DYLoadOrigIMP(cls, kDYOrigGetKey);
    // walk superclass chain if subclass has no stored IMP
    while (!orig && cls) {
        cls = class_getSuperclass(cls);
        orig = DYLoadOrigIMP(cls, kDYOrigGetKey);
    }
    id cfg = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    DYForceConfigObject(cfg);
    return cfg;
}

static void hook_msc_set(id self, SEL _cmd, id cfg) {
    DYForceConfigObject(cfg);
    Class cls = object_getClass(self);
    IMP orig = DYLoadOrigIMP(cls, kDYOrigSetKey);
    while (!orig && cls) {
        cls = class_getSuperclass(cls);
        orig = DYLoadOrigIMP(cls, kDYOrigSetKey);
    }
    if (orig) {
        ((void (*)(id, SEL, id))orig)(self, _cmd, cfg);
    }
}

static BOOL DYIsBlockedSaveKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    NSString *k = key.lowercaseString;
    if ([k isEqualToString:@"disablesave"] ||
        [k isEqualToString:@"disable_save"] ||
        [k isEqualToString:@"forbidcopy"] ||
        [k isEqualToString:@"forbid_copy"]) {
        return YES;
    }
    if ([k containsString:@"hitusernotedownloadswitch"] ||
        [k containsString:@"hitracingusernotedownloadswitch"] ||
        [k containsString:@"notallowdownload"] ||
        [k containsString:@"privacyclosenotedownload"]) {
        return YES;
    }
    return NO;
}

static BOOL DYIsForcedAllowKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    NSString *k = key.lowercaseString;
    if ([k containsString:@"usernotedownloadswitch"] ||
        [k containsString:@"uservideodownloadswitch"] ||
        [k containsString:@"shareimagesaveenable"] ||
        [k containsString:@"sharevideosaveenable"] ||
        [k containsString:@"allowdownload"] ||
        [k containsString:@"disablewatermark"] ||
        [k isEqualToString:@"isflowdownloadswitchon"] ||
        [k containsString:@"enable_save_photo"] ||
        [k isEqualToString:@"enablesave"] ||
        [k isEqualToString:@"saveenable"]) {
        return YES;
    }
    return NO;
}

// XYPHMediaSaveConfig KVC: force disableSave=NO / allow flags
static void (*orig_cfg_setValue)(id, SEL, id, NSString *);
static void hook_cfg_setValue(id self, SEL _cmd, id value, NSString *key) {
    if (DYIsBlockedSaveKey(key)) {
        value = @NO;
    } else if (DYIsForcedAllowKey(key)) {
        value = @YES;
    }
    if (orig_cfg_setValue) orig_cfg_setValue(self, _cmd, value, key);
}

static id (*orig_cfg_valueForKey)(id, SEL, NSString *);
static id hook_cfg_valueForKey(id self, SEL _cmd, NSString *key) {
    if (DYIsBlockedSaveKey(key)) return @NO;
    if (DYIsForcedAllowKey(key)) return @YES;
    return orig_cfg_valueForKey ? orig_cfg_valueForKey(self, _cmd, key) : nil;
}

static BOOL DYNameLooksNoteMedia(const char *name) {
    if (!name) return NO;
    return strstr(name, "Note") || strstr(name, "Video") || strstr(name, "Feed") ||
           strstr(name, "XYPH") || strstr(name, "XYVF") || strstr(name, "Share") ||
           strstr(name, "Media") || strstr(name, "ImageSave") || strstr(name, "NegativeFeedback");
}

static void DYInstallMediaSaveConfigLight(void) {
    Class cfgCls = objc_getClass("XYPHMediaSaveConfig");
    if (!cfgCls) return;
    DYPatchKnownClass(cfgCls);
    Method setM = class_getInstanceMethod(cfgCls, @selector(setValue:forKey:));
    if (setM) {
        IMP cur = method_getImplementation(setM);
        if (cur != (IMP)hook_cfg_setValue) {
            orig_cfg_setValue = (void *)cur;
            method_setImplementation(setM, (IMP)hook_cfg_setValue);
            LOG(@"XYPHMediaSaveConfig setValue:forKey: hooked");
        }
    }
    Method getM = class_getInstanceMethod(cfgCls, @selector(valueForKey:));
    if (getM) {
        IMP cur = method_getImplementation(getM);
        if (cur != (IMP)hook_cfg_valueForKey) {
            orig_cfg_valueForKey = (void *)cur;
            method_setImplementation(getM, (IMP)hook_cfg_valueForKey);
            LOG(@"XYPHMediaSaveConfig valueForKey: hooked");
        }
    }
}

static void DYScanMediaSaveConfigHooks(void) {
    // deferred only
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    unsigned g = 0, s = 0;
    for (unsigned int i = 0; i < n && (g < 24 || s < 24); i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!DYNameLooksNoteMedia(name)) continue;

        Method gm = class_getInstanceMethod(cls, sel_registerName("mediaSaveConfig"));
        if (gm && g < 24) {
            const char *enc = method_getTypeEncoding(gm);
            IMP prev = method_getImplementation(gm);
            if (enc && enc[0] == '@' && prev && prev != (IMP)hook_msc_get) {
                Method superM = class_getInstanceMethod(class_getSuperclass(cls), sel_registerName("mediaSaveConfig"));
                if (!superM || method_getImplementation(gm) != method_getImplementation(superM) || class_getSuperclass(cls) == Nil) {
                    DYStoreOrigIMP(cls, kDYOrigGetKey, prev);
                    method_setImplementation(gm, (IMP)hook_msc_get);
                    g++;
                }
            }
        }

        Method sm = class_getInstanceMethod(cls, sel_registerName("setMediaSaveConfig:"));
        if (sm && s < 24) {
            const char *enc = method_getTypeEncoding(sm);
            IMP prev = method_getImplementation(sm);
            if (enc && enc[0] == 'v' && prev && prev != (IMP)hook_msc_set) {
                Method superM = class_getInstanceMethod(class_getSuperclass(cls), sel_registerName("setMediaSaveConfig:"));
                if (!superM || method_getImplementation(sm) != method_getImplementation(superM) || class_getSuperclass(cls) == Nil) {
                    DYStoreOrigIMP(cls, kDYOrigSetKey, prev);
                    method_setImplementation(sm, (IMP)hook_msc_set);
                    s++;
                }
            }
        }
    }
    free(list);
    LOG(@"mediaSaveConfig scan get=%u set=%u", g, s);
}

static void DYInstallMediaSaveConfigHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DYInstallMediaSaveConfigLight();
        LOG(@"mediaSaveConfig light install (v8)");
    });
}


#pragma mark - NSUserDefaults privacy keys

static BOOL DYIsPrivacyDownloadKey(NSString *key) {
    // v1.3: keep matching narrow — broad *download* keys crash Douyin (objectForKey returns @YES for dict configs)
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    NSString *k = key.lowercaseString;
    if ([k containsString:@"privacyclosenotedownload"] ||
        [k containsString:@"hassavenotallowdownloadmyvideos"] ||
        [k containsString:@"ios_profile_privacy_user_note_download"] ||
        [k containsString:@"notallowdownloadmyvideos"] ||
        [k containsString:@"hitusernotedownload"] ||
        [k containsString:@"hitracingusernotedownload"] ||
        [k isEqualToString:@"user_note_download_switch"] ||
        [k isEqualToString:@"usernotedownloadswitch"] ||
        [k isEqualToString:@"user_video_download_switch"] ||
        [k isEqualToString:@"uservideodownloadswitch"] ||
        [k isEqualToString:@"capa_allow_download"] ||
        [k containsString:@"capa_allow_download_account"] ||
        [k isEqualToString:@"prevent_download"] ||
        [k isEqualToString:@"preventdownload"] ||
        [k isEqualToString:@"allow_download"] ||
        [k isEqualToString:@"allowdownload"] ||
        [k isEqualToString:@"can_download"] ||
        [k isEqualToString:@"candownload"]) {
        return YES;
    }
    return NO;
}

static BOOL DYPrivacyKeyShouldAllow(NSString *key) {
    // true = force YES/allow download; false = force NO/disable block flag
    NSString *k = key.lowercaseString;
    if ([k containsString:@"notallow"] ||
        [k containsString:@"privacyclose"] ||
        [k containsString:@"hitusernote"] ||
        [k containsString:@"hitracing"]) {
        return NO;
    }
    return YES;
}

static BOOL (*orig_ud_boolForKey)(id, SEL, NSString *);
static BOOL hook_ud_boolForKey(id self, SEL _cmd, NSString *key) {
    if (DYIsPrivacyDownloadKey(key)) {
        BOOL allow = DYPrivacyKeyShouldAllow(key);
        LOG(@"NSUserDefaults boolForKey:%@ => %d", key, (int)allow);
        return allow;
    }
    return orig_ud_boolForKey ? orig_ud_boolForKey(self, _cmd, key) : NO;
}

static id (*orig_ud_objectForKey)(id, SEL, NSString *);
static id hook_ud_objectForKey(id self, SEL _cmd, NSString *key) {
    id orig = orig_ud_objectForKey ? orig_ud_objectForKey(self, _cmd, key) : nil;
    if (!DYIsPrivacyDownloadKey(key)) return orig;
    // only coerce nil/NSNumber — never replace dict/string configs (startup crash)
    if (orig == nil || [orig isKindOfClass:[NSNumber class]]) {
        BOOL allow = DYPrivacyKeyShouldAllow(key);
        LOG(@"NSUserDefaults objectForKey:%@ => %d", key, (int)allow);
        return allow ? @YES : @NO;
    }
    return orig;
}

static void DYInstallUserDefaultsHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("NSUserDefaults");
        if (!cls) return;
        Method b = class_getInstanceMethod(cls, @selector(boolForKey:));
        if (b) {
            orig_ud_boolForKey = (void *)method_getImplementation(b);
            method_setImplementation(b, (IMP)hook_ud_boolForKey);
        }
        Method o = class_getInstanceMethod(cls, @selector(objectForKey:));
        if (o) {
            orig_ud_objectForKey = (void *)method_getImplementation(o);
            method_setImplementation(o, (IMP)hook_ud_objectForKey);
        }
        LOG(@"NSUserDefaults privacy keys hooked");
    });
}

#pragma mark - toast filter (download permission only)

static BOOL DYStringLooksDownloadToast(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) return NO;

    NSString *low = s.lowercaseString;
    if ([low containsString:@"capa_allow_download_account_toast"] ||
        [low containsString:@"capa_allow_download_account"] ||
        [low containsString:@"capa_allow_download"] ||
        [low containsString:@"privacyclosenotedownload"] ||
        [low containsString:@"close_note_download"] ||
        [low containsString:@"notallowdownload"] ||
        [low containsString:@"hitusernotedownload"] ||
        [low containsString:@"can't be downloaded"] ||
        [low containsString:@"cannot be downloaded"] ||
        [low containsString:@"cant be downloaded"] ||
        [low containsString:@"note text can't be copied"] ||
        [low containsString:@"note text cannot be copied"] ||
        [low containsString:@"images and videos can't be downloaded"] ||
        [low containsString:@"images and videos cannot be downloaded"]) {
        return YES;
    }

    // zh-Hans real toast: 已关闭图片与视频的下载权限，笔记正文不能被复制
    if ([s containsString:@"\u4e0b\u8f7d\u6743\u9650"] ||
        [s containsString:@"\u5df2\u5173\u95ed\u56fe\u7247\u4e0e\u89c6\u9891\u7684\u4e0b\u8f7d\u6743\u9650"] ||
        [s containsString:@"\u7b14\u8bb0\u6b63\u6587\u4e0d\u80fd\u88ab\u590d\u5236"] ||
        [s containsString:@"\u5173\u95ed\u4e0b\u8f7d"] ||
        [s containsString:@"\u4f5c\u8005\u5df2\u5173\u95ed"] ||
        [s containsString:@"\u4e0d\u5141\u8bb8\u4e0b\u8f7d"] ||
        [s containsString:@"\u4e0d\u5141\u8bb8\u4fdd\u5b58"] ||
        ([s containsString:@"\u65e0\u6cd5\u4fdd\u5b58"] && ([s containsString:@"\u4e0b\u8f7d"] || [s containsString:@"\u4f5c\u8005"])) ||
        ([s containsString:@"\u56fe\u7247"] && [s containsString:@"\u89c6\u9891"] && [s containsString:@"\u4e0b\u8f7d"] &&
         ([s containsString:@"\u6743\u9650"] || [s containsString:@"\u5173\u95ed"]))) {
        return YES;
    }
    return NO;
}

static BOOL DYIsBlockedDownloadToastText(id text) {
    if (!text || text == (id)[NSNull null]) return NO;
    if ([text isKindOfClass:[NSString class]]) {
        return DYStringLooksDownloadToast((NSString *)text);
    }
    if ([text isKindOfClass:[NSNumber class]] ||
        [text isKindOfClass:[NSData class]] ||
        [text isKindOfClass:[NSDate class]]) {
        return NO;
    }
    if ([text isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)text;
        for (id key in d) {
            if (DYIsBlockedDownloadToastText(key) || DYIsBlockedDownloadToastText(d[key])) {
                return YES;
            }
        }
        for (NSString *k in @[@"key", @"toastKey", @"i18nKey", @"messageKey", @"msgKey",
                              @"message", @"msg", @"text", @"title", @"content", @"toast",
                              @"toastText", @"toastTitle", @"desc", @"subtitle"]) {
            id v = d[k];
            if (v && DYIsBlockedDownloadToastText(v)) return YES;
        }
        return NO;
    }
    if ([text isKindOfClass:[NSArray class]]) {
        for (id x in (NSArray *)text) {
            if (DYIsBlockedDownloadToastText(x)) return YES;
        }
        return NO;
    }

    @try {
        for (NSString *k in @[@"key", @"toastKey", @"i18nKey", @"messageKey",
                              @"message", @"msg", @"text", @"title", @"content", @"toast"]) {
            SEL sel = sel_registerName(k.UTF8String);
            if (![text respondsToSelector:sel]) continue;
            id v = [text valueForKey:k];
            if (DYIsBlockedDownloadToastText(v)) return YES;
        }
    } @catch (__unused NSException *e) {}

    if ([text respondsToSelector:@selector(description)]) {
        NSString *desc = [text description];
        if (desc.length > 0 && desc.length < 512 && DYStringLooksDownloadToast(desc)) {
            return YES;
        }
    }
    return NO;
}

static BOOL DYToastArgsBlocked(id a, id b, id c) {
    return DYIsBlockedDownloadToastText(a) ||
           DYIsBlockedDownloadToastText(b) ||
           DYIsBlockedDownloadToastText(c);
}

static NSMutableDictionary *DYToastOrigMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static NSString *DYToastMapKey(Class cls, SEL sel) {
    if (!cls || !sel) return nil;
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}

static void DYToastStoreOrig(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    NSString *k = DYToastMapKey(cls, sel);
    if (!k) return;
    @synchronized (DYToastOrigMap()) {
        if (!DYToastOrigMap()[k]) {
            DYToastOrigMap()[k] = [NSValue valueWithPointer:imp];
        }
    }
}

static IMP DYToastLoadOrig(id self, SEL sel) {
    if (!self || !sel) return NULL;
    Class cls = object_getClass(self);
    while (cls) {
        NSString *k = DYToastMapKey(cls, sel);
        NSValue *v = nil;
        @synchronized (DYToastOrigMap()) {
            v = DYToastOrigMap()[k];
        }
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void hook_toast_msg1(id self, SEL _cmd, id msg) {
    if (DYIsBlockedDownloadToastText(msg)) {
        LOG(@"drop toast1: %@", msg);
        return;
    }
    IMP orig = DYToastLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, msg);
}

static void hook_toast_msg2(id self, SEL _cmd, id a, id b) {
    if (DYToastArgsBlocked(a, b, nil)) {
        LOG(@"drop toast2");
        return;
    }
    IMP orig = DYToastLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, a, b);
}

static void hook_toast_msg3(id self, SEL _cmd, id a, id b, id c) {
    if (DYToastArgsBlocked(a, b, c)) {
        LOG(@"drop toast3");
        return;
    }
    IMP orig = DYToastLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id, id))orig)(self, _cmd, a, b, c);
}

static void hook_toast_inview(id self, SEL _cmd, id view, id msg) {
    if (DYIsBlockedDownloadToastText(msg)) {
        LOG(@"drop toastInView: %@", msg);
        return;
    }
    IMP orig = DYToastLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, view, msg);
}

static BOOL DYNameLooksToastHost(const char *name) {
    if (!name) return NO;
    return strstr(name, "Toast") ||
           strstr(name, "Alert") ||
           strstr(name, "Tip") ||
           strstr(name, "HUD") ||
           strstr(name, "XYPH") ||
           strstr(name, "XYUI") ||
           strstr(name, "XYST") ||
           strstr(name, "Scarlet") ||
           strstr(name, "Zeus") ||
           strstr(name, "Capa") ||
           strstr(name, "I18n") ||
           strstr(name, "I18N") ||
           strstr(name, "NegativeFeedback") ||
           strstr(name, "Horizon");
}

static void DYTryHookToastMethod(Class cls, const char *selName, IMP hook, unsigned *count, unsigned maxCount) {
    if (!cls || !selName || !hook || !count || *count >= maxCount) return;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    BOOL isClassMethod = NO;
    if (!m) {
        m = class_getClassMethod(cls, sel);
        isClassMethod = (m != NULL);
    }
    if (!m) return;

    Class target = isClassMethod ? object_getClass(cls) : cls;
    Method own = class_getInstanceMethod(target, sel);
    if (!own) return;
    Method superM = class_getInstanceMethod(class_getSuperclass(target), sel);
    if (superM && method_getImplementation(own) == method_getImplementation(superM)) {
        return;
    }

    IMP cur = method_getImplementation(own);
    if (cur == hook) return;
    DYToastStoreOrig(target, sel, cur);
    method_setImplementation(own, hook);
    (*count)++;
    LOG(@"toast hook %s %s", class_getName(cls), selName);
}

static void DYInstallToastFiltersKnown(void) {
    const char *known[] = {
        "XYAlertUtils",
        "XYAlert",
        "XYAlertTextHUD",
        "XYTipsManager",
        "XYTipsView",
        "XYToastEventHandler",
        "XYPHToast",
        "XYHUD",
        "XYSTToast",
        "ScarletToast",
        "ZeusToastMessage",
        "DYAToastManager",
        "DYAToastView",
        "__Toast__",
        "XYCapaToastEventHandler",
        "_TtC11XYCameraKit19XYToastEventHandler",
        NULL
    };

    unsigned c1 = 0, c2 = 0, c3 = 0, cv = 0;
    for (const char **p = known; *p; p++) {
        Class cls = objc_getClass(*p);
        if (!cls) continue;
        DYTryHookToastMethod(cls, "showToastWithMessage:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showToast:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showToastOnMainThread:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showToastOnMainThreadWith:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showToastWithTitle:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showTextToastOnMiddle:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showErrorToastWithMessage:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showFailToastWithTip:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showTipsWithKey:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showWithToast:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showToastWithData:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "toastMsgInMainThreadWith:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "displayToastIfContentAvailable:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "horizon_asyn_showToastNew:", (IMP)hook_toast_msg1, &c1, 20);
        DYTryHookToastMethod(cls, "showToast:msg:", (IMP)hook_toast_msg2, &c2, 20);
        DYTryHookToastMethod(cls, "showToastWithMessage:to:", (IMP)hook_toast_msg2, &c2, 20);
        DYTryHookToastMethod(cls, "showToastWithMessage:withKey:", (IMP)hook_toast_msg2, &c2, 20);
        DYTryHookToastMethod(cls, "showErrorToastWithI18nKey:errorCode:", (IMP)hook_toast_msg2, &c2, 20);
        DYTryHookToastMethod(cls, "showToast:supportAccessibility:", (IMP)hook_toast_msg2, &c2, 20);
        DYTryHookToastMethod(cls, "showLivePhotoToastIfNeededWithToast:key:", (IMP)hook_toast_msg2, &c2, 20);
        DYTryHookToastMethod(cls, "showToastInView:message:", (IMP)hook_toast_inview, &cv, 16);
        DYTryHookToastMethod(cls, "showToastWithEvent:params:callback:", (IMP)hook_toast_msg3, &c3, 16);
        DYTryHookToastMethod(cls, "_executeShowToast:context:completion:", (IMP)hook_toast_msg3, &c3, 16);
        DYTryHookToastMethod(cls, "showToastWithToast:adjustKeyboard:offset:", (IMP)hook_toast_msg3, &c3, 16);
        DYTryHookToastMethod(cls, "toast:callback:", (IMP)hook_toast_msg2, &c2, 16);
    }
    LOG(@"toast known c1=%u c2=%u c3=%u cv=%u", c1, c2, c3, cv);
}

static void DYScanToastFilters(void) {
    // deferred only - keep bounds tight
    unsigned c1 = 0, c2 = 0, c3 = 0, cv = 0;
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n && (c1 < 20 || c2 < 16 || c3 < 10 || cv < 10); i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!DYNameLooksToastHost(name)) continue;
        if (class_getInstanceMethod(cls, sel_registerName("showToastWithMessage:")) ||
            class_getInstanceMethod(cls, sel_registerName("showToast:")) ||
            class_getInstanceMethod(cls, sel_registerName("showToastWithMessage:withKey:")) ||
            class_getInstanceMethod(cls, sel_registerName("showToastWithData:")) ||
            class_getInstanceMethod(cls, sel_registerName("showToastWithEvent:params:callback:")) ||
            class_getInstanceMethod(cls, sel_registerName("_executeShowToast:context:completion:")) ||
            class_getInstanceMethod(cls, sel_registerName("showToastInView:message:")) ||
            class_getInstanceMethod(cls, sel_registerName("showTipsWithKey:")) ||
            class_getInstanceMethod(cls, sel_registerName("showErrorToastWithI18nKey:errorCode:")) ||
            class_getInstanceMethod(cls, sel_registerName("displayToastIfContentAvailable:")) ||
            class_getInstanceMethod(cls, sel_registerName("horizon_asyn_showToastNew:")) ||
            class_getInstanceMethod(cls, sel_registerName("showToastWithToast:adjustKeyboard:offset:")) ||
            class_getInstanceMethod(cls, sel_registerName("showToast:supportAccessibility:"))) {
            DYTryHookToastMethod(cls, "showToastWithMessage:", (IMP)hook_toast_msg1, &c1, 20);
            DYTryHookToastMethod(cls, "showToast:", (IMP)hook_toast_msg1, &c1, 20);
            DYTryHookToastMethod(cls, "showToastWithData:", (IMP)hook_toast_msg1, &c1, 20);
            DYTryHookToastMethod(cls, "showTipsWithKey:", (IMP)hook_toast_msg1, &c1, 20);
            DYTryHookToastMethod(cls, "showFailToastWithTip:", (IMP)hook_toast_msg1, &c1, 20);
            DYTryHookToastMethod(cls, "showErrorToastWithMessage:", (IMP)hook_toast_msg1, &c1, 20);
            DYTryHookToastMethod(cls, "displayToastIfContentAvailable:", (IMP)hook_toast_msg1, &c1, 20);
            DYTryHookToastMethod(cls, "horizon_asyn_showToastNew:", (IMP)hook_toast_msg1, &c1, 20);
            DYTryHookToastMethod(cls, "showToastWithMessage:withKey:", (IMP)hook_toast_msg2, &c2, 16);
            DYTryHookToastMethod(cls, "showToastWithMessage:to:", (IMP)hook_toast_msg2, &c2, 16);
            DYTryHookToastMethod(cls, "showErrorToastWithI18nKey:errorCode:", (IMP)hook_toast_msg2, &c2, 16);
            DYTryHookToastMethod(cls, "showToast:supportAccessibility:", (IMP)hook_toast_msg2, &c2, 16);
            DYTryHookToastMethod(cls, "showToastWithEvent:params:callback:", (IMP)hook_toast_msg3, &c3, 10);
            DYTryHookToastMethod(cls, "_executeShowToast:context:completion:", (IMP)hook_toast_msg3, &c3, 10);
            DYTryHookToastMethod(cls, "showToastWithToast:adjustKeyboard:offset:", (IMP)hook_toast_msg3, &c3, 10);
            DYTryHookToastMethod(cls, "showToastInView:message:", (IMP)hook_toast_inview, &cv, 10);
        }
    }
    free(list);
    LOG(@"toast scan c1=%u c2=%u c3=%u cv=%u", c1, c2, c3, cv);
}

static void DYInstallToastFilters(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DYInstallToastFiltersKnown();
        LOG(@"toast filters known-only (v8)");
    });
}

static BOOL DYIsBlockedI18nKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    NSString *k = key.lowercaseString;
    return [k containsString:@"capa_allow_download_account_toast"] ||
           [k isEqualToString:@"capa_allow_download_account"] ||
           [k containsString:@"privacyclosenotedownload"] ||
           [k containsString:@"close_note_download"] ||
           [k containsString:@"notallowdownloadmyvideos"];
}

static NSMutableDictionary *DYI18nOrigMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static void DYI18nStoreOrig(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
    @synchronized (DYI18nOrigMap()) {
        if (!DYI18nOrigMap()[k]) {
            DYI18nOrigMap()[k] = [NSValue valueWithPointer:imp];
        }
    }
}

static IMP DYI18nLoadOrig(id self, SEL sel) {
    if (!self || !sel) return NULL;
    Class cls = object_getClass(self);
    while (cls) {
        NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
        NSValue *v = nil;
        @synchronized (DYI18nOrigMap()) {
            v = DYI18nOrigMap()[k];
        }
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static id hook_i18n_key1(id self, SEL _cmd, id key) {
    if (DYIsBlockedI18nKey(key) || DYIsBlockedDownloadToastText(key)) {
        LOG(@"i18n drop key1: %@", key);
        return @"";
    }
    IMP orig = DYI18nLoadOrig(self, _cmd);
    return orig ? ((id (*)(id, SEL, id))orig)(self, _cmd, key) : nil;
}

static id hook_i18n_key2(id self, SEL _cmd, id key, id fallback) {
    if (DYIsBlockedI18nKey(key) || DYIsBlockedDownloadToastText(key)) {
        LOG(@"i18n drop key2: %@", key);
        return @"";
    }
    // also block if fallback itself is the download toast body
    if (DYIsBlockedDownloadToastText(fallback)) {
        LOG(@"i18n drop fallback toast body");
        return @"";
    }
    IMP orig = DYI18nLoadOrig(self, _cmd);
    return orig ? ((id (*)(id, SEL, id, id))orig)(self, _cmd, key, fallback) : nil;
}

static id hook_i18n_module_key(id self, SEL _cmd, id module, id key) {
    if (DYIsBlockedI18nKey(key) || DYIsBlockedDownloadToastText(key) ||
        DYIsBlockedI18nKey(module) || DYIsBlockedDownloadToastText(module)) {
        LOG(@"i18n drop module+key");
        return @"";
    }
    IMP orig = DYI18nLoadOrig(self, _cmd);
    return orig ? ((id (*)(id, SEL, id, id))orig)(self, _cmd, module, key) : nil;
}

static id hook_i18n_cfg_key(id self, SEL _cmd, id cfg, id key, id def) {
    if (DYIsBlockedI18nKey(key) || DYIsBlockedDownloadToastText(key)) {
        LOG(@"i18n drop cfg key: %@", key);
        return @"";
    }
    if (DYIsBlockedDownloadToastText(def)) return @"";
    IMP orig = DYI18nLoadOrig(self, _cmd);
    return orig ? ((id (*)(id, SEL, id, id, id))orig)(self, _cmd, cfg, key, def) : nil;
}

static void DYTryHookI18nMethod(Class cls, const char *selName, IMP hook, unsigned *count, unsigned maxCount) {
    if (!cls || !selName || !hook || !count || *count >= maxCount) return;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    BOOL isClassMethod = NO;
    if (!m) {
        m = class_getClassMethod(cls, sel);
        isClassMethod = (m != NULL);
    }
    if (!m) return;
    Class target = isClassMethod ? object_getClass(cls) : cls;
    Method own = class_getInstanceMethod(target, sel);
    if (!own) return;
    Method superM = class_getInstanceMethod(class_getSuperclass(target), sel);
    if (superM && method_getImplementation(own) == method_getImplementation(superM)) return;
    IMP cur = method_getImplementation(own);
    if (cur == hook) return;
    const char *enc = method_getTypeEncoding(own);
    if (!enc || enc[0] != '@') return;
    DYI18nStoreOrig(target, sel, cur);
    method_setImplementation(own, hook);
    (*count)++;
    LOG(@"i18n hook %s %s", class_getName(cls), selName);
}

static BOOL DYNameLooksI18nHost(const char *name) {
    if (!name) return NO;
    return strstr(name, "I18n") ||
           strstr(name, "I18N") ||
           strstr(name, "RedI18N") ||
           strstr(name, "Localize") ||
           strstr(name, "Localization") ||
           strstr(name, "Language") ||
           strstr(name, "XYAlert") ||
           strstr(name, "Toast") ||
           strstr(name, "Tips");
}

static void DYInstallI18nFiltersKnown(void) {
    const char *known[] = {
        "_TtC7RedI18N14I18nI18NModule",
        "I18nI18NModule",
        "RedI18N",
        "XYAlertUtils",
        "XYTipsManager",
        "XYToastEventHandler",
        NULL
    };
    unsigned c1 = 0, c2 = 0, c3 = 0;
    for (const char **p = known; *p; p++) {
        Class cls = objc_getClass(*p);
        if (!cls) continue;
        DYTryHookI18nMethod(cls, "getStringWithKey:", (IMP)hook_i18n_key1, &c1, 16);
        DYTryHookI18nMethod(cls, "getStringWithKey:defaultValue:", (IMP)hook_i18n_key2, &c2, 16);
        DYTryHookI18nMethod(cls, "localizedStringWithKey:", (IMP)hook_i18n_key1, &c1, 16);
        DYTryHookI18nMethod(cls, "localizedStringWithKey:fallbackValue:", (IMP)hook_i18n_key2, &c2, 16);
        DYTryHookI18nMethod(cls, "localizedStringWithKey:comment:", (IMP)hook_i18n_key2, &c2, 16);
        DYTryHookI18nMethod(cls, "localizedStringWithModuleStr:key:", (IMP)hook_i18n_module_key, &c2, 16);
        DYTryHookI18nMethod(cls, "localizedStringFromConfig:key:defaultString:", (IMP)hook_i18n_cfg_key, &c3, 12);
    }
    LOG(@"i18n known c1=%u c2=%u c3=%u", c1, c2, c3);
}

static void DYScanI18nFilters(void) {
    unsigned c1 = 0, c2 = 0, c3 = 0;
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n && (c1 < 16 || c2 < 16 || c3 < 8); i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!DYNameLooksI18nHost(name)) continue;
        if (class_getInstanceMethod(cls, sel_registerName("getStringWithKey:")) ||
            class_getInstanceMethod(cls, sel_registerName("localizedStringWithKey:")) ||
            class_getInstanceMethod(cls, sel_registerName("localizedStringWithKey:fallbackValue:")) ||
            class_getClassMethod(cls, sel_registerName("getStringWithKey:")) ||
            class_getClassMethod(cls, sel_registerName("localizedStringWithKey:"))) {
            DYTryHookI18nMethod(cls, "getStringWithKey:", (IMP)hook_i18n_key1, &c1, 16);
            DYTryHookI18nMethod(cls, "getStringWithKey:defaultValue:", (IMP)hook_i18n_key2, &c2, 16);
            DYTryHookI18nMethod(cls, "localizedStringWithKey:", (IMP)hook_i18n_key1, &c1, 16);
            DYTryHookI18nMethod(cls, "localizedStringWithKey:fallbackValue:", (IMP)hook_i18n_key2, &c2, 16);
            DYTryHookI18nMethod(cls, "localizedStringWithKey:comment:", (IMP)hook_i18n_key2, &c2, 16);
            DYTryHookI18nMethod(cls, "localizedStringWithModuleStr:key:", (IMP)hook_i18n_module_key, &c2, 12);
            DYTryHookI18nMethod(cls, "localizedStringFromConfig:key:defaultString:", (IMP)hook_i18n_cfg_key, &c3, 8);
        }
    }
    free(list);
    LOG(@"i18n scan c1=%u c2=%u c3=%u", c1, c2, c3);
}

static void DYInstallI18nFilters(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DYInstallI18nFiltersKnown();
        LOG(@"i18n filters known-only (v8)");
    });
}


#pragma mark - NSBundle localizedString (capa toast key)

static NSString *(*orig_bundle_localized)(id, SEL, NSString *, NSString *, NSString *);
static NSString *hook_bundle_localized(id self, SEL _cmd, NSString *key, NSString *value, NSString *table) {
    if (DYIsBlockedI18nKey(key) || DYIsBlockedDownloadToastText(key) ||
        DYIsBlockedDownloadToastText(value)) {
        LOG(@"bundle i18n drop: %@ / %@", key, table);
        return @"";
    }
    return orig_bundle_localized ? orig_bundle_localized(self, _cmd, key, value, table) : (value ?: @"");
}

static void DYInstallBundleI18nHook(void) {
    // v8: NEVER hook NSBundle localizedStringForKey - ultra-hot path, launch hang.
    (void)hook_bundle_localized;
    (void)orig_bundle_localized;
    LOG(@"NSBundle localizedString skipped (v8)");
}

#pragma mark - ImageSaveService native save entry

static NSMutableDictionary *DYSaveOrigMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static void DYSaveStoreOrig(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
    @synchronized (DYSaveOrigMap()) {
        if (!DYSaveOrigMap()[k]) {
            DYSaveOrigMap()[k] = [NSValue valueWithPointer:imp];
        }
    }
}

static IMP DYSaveLoadOrig(id self, SEL sel) {
    Class cls = object_getClass(self);
    while (cls) {
        NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
        NSValue *v = nil;
        @synchronized (DYSaveOrigMap()) {
            v = DYSaveOrigMap()[k];
        }
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void hook_saveImageList(id self, SEL _cmd, id from, BOOL disableWatermark, id completion) {
    (void)disableWatermark;
    LOG(@"force saveImageList disableWatermark=YES");
    IMP orig = DYSaveLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, BOOL, id))orig)(self, _cmd, from, YES, completion);
}

static void hook_saveImageAt(id self, SEL _cmd, id at, id from, BOOL disableWatermark, id completion) {
    (void)disableWatermark;
    LOG(@"force saveImageAt disableWatermark=YES");
    IMP orig = DYSaveLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id, BOOL, id))orig)(self, _cmd, at, from, YES, completion);
}

static void hook_saveImageNoTrack(id self, SEL _cmd, id at, id from, BOOL disableWatermark, id completion) {
    (void)disableWatermark;
    LOG(@"force saveImageNoTrack disableWatermark=YES");
    IMP orig = DYSaveLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id, BOOL, id))orig)(self, _cmd, at, from, YES, completion);
}

static void hook_saveOriginalList(id self, SEL _cmd, id from, id completion) {
    LOG(@"saveOriginalImageList pass");
    IMP orig = DYSaveLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, from, completion);
}

static void DYTryHookSaveMethod(Class cls, const char *selName, IMP hook, unsigned *count) {
    if (!cls || !selName || !hook) return;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    Method superM = class_getInstanceMethod(class_getSuperclass(cls), sel);
    if (superM && method_getImplementation(m) == method_getImplementation(superM)) return;
    IMP cur = method_getImplementation(m);
    if (cur == hook) return;
    DYSaveStoreOrig(cls, sel, cur);
    method_setImplementation(m, hook);
    if (count) (*count)++;
    LOG(@"save hook %s %s", class_getName(cls), selName);
}

static void DYInstallSaveMethodHooksKnown(void) {
    const char *classes[] = {
        "_TtC12XYNoteModule16ImageSaveService",
        "ImageSaveService",
        "_TtC18XYNegativeFeedback16SaveImageService",
        "SaveImageService",
        "_TtC6XYDots20DotsImageSaveService",
        "DotsImageSaveService",
        NULL
    };
    unsigned c = 0;
    for (const char **p = classes; *p; p++) {
        Class cls = objc_getClass(*p);
        if (!cls) continue;
        DYPatchKnownClass(cls);
        DYTryHookSaveMethod(cls, "saveImageListFrom:disableWatermark:saveAllCompletion:", (IMP)hook_saveImageList, &c);
        DYTryHookSaveMethod(cls, "saveImageAt:from:disableWatermark:completion:", (IMP)hook_saveImageAt, &c);
        DYTryHookSaveMethod(cls, "saveImageWithoutManualTrackAt:from:disableWatermark:completion:", (IMP)hook_saveImageNoTrack, &c);
        DYTryHookSaveMethod(cls, "saveOriginalImageListFrom:saveAllCompletion:", (IMP)hook_saveOriginalList, &c);
    }
    LOG(@"save method known hooks=%u", c);
}

static void DYScanSaveMethodHooks(void) {
    unsigned c = 0;
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n && c < 16; i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!name) continue;
        if (!(strstr(name, "ImageSave") || strstr(name, "SaveImage") || strstr(name, "MediaSave"))) continue;
        DYPatchKnownClass(cls);
        DYTryHookSaveMethod(cls, "saveImageListFrom:disableWatermark:saveAllCompletion:", (IMP)hook_saveImageList, &c);
        DYTryHookSaveMethod(cls, "saveImageAt:from:disableWatermark:completion:", (IMP)hook_saveImageAt, &c);
        DYTryHookSaveMethod(cls, "saveImageWithoutManualTrackAt:from:disableWatermark:completion:", (IMP)hook_saveImageNoTrack, &c);
    }
    free(list);
    LOG(@"save method scan hooks=%u", c);
}

static void DYInstallSaveMethodHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DYInstallSaveMethodHooksKnown();
        LOG(@"save method hooks known-only (v8)");
    });
}

static void DYInstallAuthorityPatchesKnown(void) {
    const char *known[] = {
        "XYPHMediaSaveConfig",
        "XYNoteFeedbackFloatingConfig",
        "NoteFeedbackFloatingConfig",
        "_TtC18XYNegativeFeedback12SaveProvider",
        "SaveProvider",
        NULL
    };
    for (const char **p = known; *p; p++) {
        Class cls = objc_getClass(*p);
        if (!cls) continue;
        DYPatchKnownClass(cls);
        DYPatchBool(cls, "hasDownloadMyNotesAuthorityData", YES);
        DYPatchBool(cls, "hasSaveNotAllowDownloadMyVideosKey", NO);
    }
}

static void DYScanAuthorityPatches(void) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    unsigned patched = 0;
    for (unsigned int i = 0; i < n && patched < 24; i++) {
        Class cls = list[i];
        BOOL hit = NO;
        if (class_getInstanceMethod(cls, sel_registerName("hasDownloadMyNotesAuthorityData")) ||
            class_getInstanceMethod(cls, sel_registerName("downloadMyNotesAuthorityData")) ||
            class_getInstanceMethod(cls, sel_registerName("hasSaveNotAllowDownloadMyVideosKey")) ||
            class_getInstanceMethod(cls, sel_registerName("privacyCloseNoteDownloadKey")) ||
            class_getInstanceMethod(cls, sel_registerName("userNoteDownloadSwitch")) ||
            class_getInstanceMethod(cls, sel_registerName("hitUserNoteDownloadSwitch"))) {
            hit = YES;
        }
        if (!hit) continue;
        DYPatchKnownClass(cls);
        DYPatchBool(cls, "hasDownloadMyNotesAuthorityData", YES);
        DYPatchBool(cls, "hasSaveNotAllowDownloadMyVideosKey", NO);
        patched++;
    }
    free(list);
    LOG(@"authority scan patches=%u", patched);
}

static void DYInstallAuthorityPatches(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        DYInstallAuthorityPatchesKnown();
        LOG(@"authority patches known-only (v8)");
    });
}


#pragma mark - fallback save (float button / 2-finger long press)

// Native flag flips alone are not enough on 9.38.1 when author closes download.
// Fallback grabs current image/video URL (or UIImage) and writes Photos itself.

static void DYFallbackAuthThen(void (^block)(BOOL granted)) {
    void (^finish)(PHAuthorizationStatus) = ^(PHAuthorizationStatus st) {
        BOOL g = (st == PHAuthorizationStatusAuthorized);
        if (@available(iOS 14, *)) {
            g = g || (st == PHAuthorizationStatusLimited);
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (block) block(g); });
    };
    if (@available(iOS 14, *)) {
        PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        if (st == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:finish];
        } else {
            finish(st);
        }
    } else {
        PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatus];
        if (st == PHAuthorizationStatusNotDetermined) {
            [PHPhotoLibrary requestAuthorization:finish];
        } else {
            finish(st);
        }
    }
}

static void DYFallbackSaveImage(UIImage *image, void (^done)(BOOL, NSError *)) {
    if (!image) {
        if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:1
                              userInfo:@{NSLocalizedDescriptionKey: @"nil image"}]);
        return;
    }
    DYFallbackAuthThen(^(BOOL granted) {
        if (!granted) {
            if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:2
                                  userInfo:@{NSLocalizedDescriptionKey: @"album permission denied"}]);
            return;
        }
        __block NSString *localId = nil;
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetChangeRequest *req = [PHAssetChangeRequest creationRequestForAssetFromImage:image];
            localId = req.placeholderForCreatedAsset.localIdentifier;
        } completionHandler:^(BOOL success, NSError *error) {
            NSLog(@"[DouyinSave] photos write image success=%d id=%@ err=%@", (int)success, localId, error);
            BOOL really = success && localId.length > 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (done) done(really, really ? nil : (error ?:
                    [NSError errorWithDomain:@"DouyinSave" code:3302
                                    userInfo:@{NSLocalizedDescriptionKey: @"Photos rejected image"}]));
            });
        }];
    });
}

static void DYFallbackSaveData(NSData *data, void (^done)(BOOL, NSError *)) {
    if (data.length < 32) {
        if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:3
                              userInfo:@{NSLocalizedDescriptionKey: @"empty data"}]);
        return;
    }
    UIImage *img = [UIImage imageWithData:data];
    if (img) {
        DYFallbackSaveImage(img, done);
        return;
    }
    DYFallbackAuthThen(^(BOOL granted) {
        if (!granted) {
            if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:2
                                  userInfo:@{NSLocalizedDescriptionKey: @"album permission denied"}]);
            return;
        }
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"dy_fb_%@.img", NSUUID.UUID.UUIDString]];
        if (![data writeToFile:path atomically:YES]) {
            if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:4
                                  userInfo:@{NSLocalizedDescriptionKey: @"write tmp fail"}]);
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:[NSURL fileURLWithPath:path]];
        } completionHandler:^(BOOL success, NSError *error) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(success, error); });
        }];
    });
}

static UIWindow *DYFallbackKeyWindow(void) {
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        if (ws.activationState != UISceneActivationStateForegroundActive &&
            ws.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow) return w;
        }
        if (ws.windows.count) return ws.windows.firstObject;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIWindow *legacy = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    return legacy;
}

static void DYFallbackToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = DYFallbackKeyWindow();
        if (!win) return;
        UILabel *lab = [UILabel new];
        lab.text = msg;
        lab.textColor = UIColor.whiteColor;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        lab.font = [UIFont boldSystemFontOfSize:14];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.numberOfLines = 0;
        lab.layer.cornerRadius = 10;
        lab.clipsToBounds = YES;
        CGSize fit = [lab sizeThatFits:CGSizeMake(win.bounds.size.width - 72, 160)];
        lab.frame = CGRectMake(0, 0, fit.width + 28, fit.height + 16);
        lab.center = CGPointMake(CGRectGetMidX(win.bounds), win.bounds.size.height * 0.78);
        [win addSubview:lab];
        [UIView animateWithDuration:0.2 delay:1.6 options:0 animations:^{ lab.alpha = 0; }
                         completion:^(__unused BOOL f) { [lab removeFromSuperview]; }];
    });
}

static BOOL DYFallbackLooksMediaHost(NSString *l) {
    if (!l.length) return NO;
    return [l containsString:@"douyin"] ||
           [l containsString:@"iesdouyin"] ||
           [l containsString:@"bytecdn"] ||
           [l containsString:@"byteimg"] ||
           [l containsString:@"snssdk"] ||
           [l containsString:@"toutiao"] ||
           [l containsString:@"tiktok"] ||
           [l containsString:@"pstatp"] ||
           [l containsString:@"bytedance"] ||
           [l containsString:@"bytegecko"] ||
           [l containsString:@"zjcdn"] ||
           [l containsString:@"ixigua"] ||
           [l containsString:@"aweme"] ||
           [l containsString:@"cdn-tos"] ||
           [l containsString:@"tos-cn"] ||
           [l containsString:@"vlabvod"] ||
           [l containsString:@"bytevcloud"] ||
           [l containsString:@"ibytedtos"] ||
           [l containsString:@"douyinvod"] ||
           [l containsString:@"douyinpic"] ||
           [l containsString:@"volces.com"] ||
           [l containsString:@"byted.org"];
}

static BOOL DYFallbackIsVideoURL(NSString *s) {
    if (s.length < 8) return NO;
    NSString *l = s.lowercaseString;
    // hard image hosts / templates
    if ([l containsString:@"byteimg"] || [l containsString:@"douyinpic"] ||
        [l containsString:@"~tplv-"] || [l containsString:@"imageview2"] ||
        [l containsString:@"fmt=jpeg"] || [l containsString:@"fmt=png"] ||
        [l containsString:@"fmt=webp"] || [l containsString:@"fmt=heic"]) {
        if (![l containsString:@".mp4"] && ![l containsString:@"mime_type=video"]) return NO;
    }
    // explicit image extensions are not video (cover frames)
    if (([l containsString:@".jpg"] || [l containsString:@".jpeg"] ||
         [l containsString:@".png"] || [l containsString:@".webp"] ||
         [l containsString:@".heic"] || [l containsString:@".gif"] ||
         [l containsString:@".bmp"]) &&
        ![l containsString:@".mp4"] && ![l containsString:@"mime_type=video"]) {
        return NO;
    }
    if (([l containsString:@"cover"] || [l containsString:@"avatar"] ||
         [l containsString:@"thumb"] || [l containsString:@"head"]) &&
        ![l containsString:@".mp4"] && ![l containsString:@"video_id"] &&
        ![l containsString:@"/aweme/v1/play"]) {
        return NO;
    }
    if ([l containsString:@".m3u8"] || [l containsString:@".mp4"] ||
        [l containsString:@".m4v"] || [l containsString:@".mov"] ||
        [l containsString:@".flv"]) return YES;
    if ([l containsString:@"mime_type=video"] || [l containsString:@"media_type=video"] ||
        [l containsString:@"content-type=video"]) return YES;
    // strong Douyin video endpoints / vod hosts
    if ([l containsString:@"play_addr"] || [l containsString:@"playaddr"] ||
        [l containsString:@"download_addr"] || [l containsString:@"downloadaddr"] ||
        [l containsString:@"bytevcloud"] || [l containsString:@"vlabvod"] ||
        [l containsString:@"douyinvod"] || [l containsString:@"video_id="] ||
        [l containsString:@"/aweme/v1/play"] || [l containsString:@"/aweme/v1/playwm"] ||
        [l containsString:@"media-video"] || [l containsString:@"video_mp4"] ||
        [l containsString:@"/video/tos/"] || [l containsString:@"/obj/ies-music/"] ||
        [l containsString:@"/obj/tos-"] || [l containsString:@"mime_type%3dvideo"] ||
        [l containsString:@"mime_type%3Dvideo"]) return YES;
    // progressive CDN: require video-ish path segment, NOT bare /obj/
    if (([l containsString:@"tos-cn"] || [l containsString:@"cdn-tos"] ||
         [l containsString:@"bytecdn"] || [l containsString:@"snssdk"] ||
         [l containsString:@"volces.com"] || [l containsString:@"bytedance"] ||
         [l containsString:@"iesdouyin"] || [l containsString:@"douyinvod"] ||
         [l containsString:@"ibytedtos"]) &&
        ([l containsString:@"/video/"] || [l containsString:@"video/"] ||
         [l containsString:@"vod"] || [l containsString:@"stream"] ||
         [l containsString:@"play"] || [l containsString:@"media-video"] ||
         [l containsString:@"download"])) {
        if ([l containsString:@"cover"] || [l containsString:@"avatar"] ||
            [l containsString:@"thumb"] || [l containsString:@"icon"] ||
            [l containsString:@"image"]) return NO;
        return YES;
    }
    if ([l hasPrefix:@"file:"] &&
        ([l containsString:@".mp4"] || [l containsString:@".mov"] ||
         [l containsString:@".m4v"])) return YES;
    if ([l hasPrefix:@"/"] &&
        ([l hasSuffix:@".mp4"] || [l hasSuffix:@".mov"] || [l hasSuffix:@".m4v"])) return YES;
    return NO;
}

static BOOL DYFallbackIsImageURL(NSString *s) {
    if (s.length < 12) return NO;
    NSString *l = s.lowercaseString;
    if (![l hasPrefix:@"http"]) return NO;
    if (DYFallbackIsVideoURL(s)) return NO;
    if ([l containsString:@"byteimg"] || [l containsString:@"douyinpic"] ||
        [l containsString:@"~tplv-"] || [l containsString:@"avatar"] ||
        [l containsString:@"cover"] || [l containsString:@"thumb"]) return YES;
    return [l containsString:@".jpg"] ||
           [l containsString:@".jpeg"] ||
           [l containsString:@".png"] ||
           [l containsString:@".webp"] ||
           [l containsString:@".heic"] ||
           [l containsString:@"fmt=jpeg"] ||
           [l containsString:@"fmt=png"] ||
           [l containsString:@"fmt=webp"] ||
           [l containsString:@"/image"] ||
           [l containsString:@"imageView2"];
}

static BOOL DYFallbackIsMediaURL(NSString *s) {
    return DYFallbackIsVideoURL(s) || DYFallbackIsImageURL(s);
}

static void DYFallbackCollect(id obj, NSMutableSet<NSString *> *out, NSInteger depth) {
    if (!obj || depth > 10 || out.count > 120) return;
    if ([obj isKindOfClass:[NSString class]]) {
        if (DYFallbackIsMediaURL((NSString *)obj)) [out addObject:(NSString *)obj];
        return;
    }
    if ([obj isKindOfClass:[NSURL class]]) {
        NSString *s = [(NSURL *)obj absoluteString];
        if (DYFallbackIsMediaURL(s)) [out addObject:s];
        return;
    }
    // live player asset -> real stream URL / local cache file
    if ([obj isKindOfClass:[AVURLAsset class]]) {
        NSString *s = [(AVURLAsset *)obj URL].absoluteString;
        if (DYFallbackIsMediaURL(s) || [s hasPrefix:@"file:"]) [out addObject:s];
        return;
    }
    if ([obj isKindOfClass:[AVPlayerItem class]]) {
        DYFallbackCollect([(AVPlayerItem *)obj asset], out, depth + 1);
        return;
    }
    if ([obj isKindOfClass:[AVPlayer class]]) {
        DYFallbackCollect([(AVPlayer *)obj currentItem], out, depth + 1);
        return;
    }
    // Douyin often uses non-AVPlayer engines; probe KVC only on player/model-like classes
    // (blind valueForKey on random UIKit/Foundation objects can crash Aweme)
    if (depth < 3 && [obj isKindOfClass:[NSObject class]]) {
        const char *cn = object_getClassName(obj);
        BOOL looksPlayer = cn && (
            strstr(cn, "Player") || strstr(cn, "Video") || strstr(cn, "Aweme") ||
            strstr(cn, "Engine") || strstr(cn, "Play") || strstr(cn, "Media") ||
            strstr(cn, "URLModel") || strstr(cn, "Downloader"));
        if (!looksPlayer) {
            // skip generic NSObject engine walk
        } else {
        static NSArray<NSString *> *engineKeys;
        static dispatch_once_t onceEK;
        dispatch_once(&onceEK, ^{
            engineKeys = @[
                @"currentURL", @"currentUrl", @"playURL", @"playUrl", @"videoURL", @"videoUrl",
                @"contentURL", @"assetURL", @"localURL", @"localUrl",
                @"cacheFilePath", @"cachePath", @"filePath", @"videoPath", @"localPath",
                @"originURL", @"originUrl", @"downloadURL", @"downloadUrl",
                @"playAddr", @"downloadAddr", @"urlList", @"url_list",
                @"videoEngine", @"ttVideoEngine", @"player", @"videoPlayer",
                @"iesVideoPlayer", @"playerItem", @"currentItem", @"model",
                @"awemeModel", @"aweme", @"video", @"videoModel", @"currentAweme",
                @"currentPlayURL", @"playbackURL", @"videoURLString", @"playURLString",
                @"downloadAddrModel", @"playAddrModel", @"playAddrH264Model",
                @"originDownloadAddr", @"originDownloadAddrModel",
                @"bitRate", @"bit_rate", @"bitRateList", @"bit_rate_list",
                @"playAddrList", @"downloadAddrList", @"videoBitRate",
                @"h264DownloadAddr", @"h265DownloadAddr", @"HDRBitRateList"
            ];
        });
        for (NSString *k in engineKeys) {
            @try {
                id v = [obj valueForKey:k];
                if (v && v != obj) DYFallbackCollect(v, out, depth + 1);
            } @catch (__unused NSException *e) {}
        }
        // some engines expose URL via method without KVC property
        @try {
            SEL s1 = sel_registerName("currentURL");
            if ([obj respondsToSelector:s1]) {
                id u = ((id (*)(id, SEL))objc_msgSend)(obj, s1);
                DYFallbackCollect(u, out, depth + 1);
            }
        } @catch (__unused NSException *e) {}
        @try {
            SEL s1 = sel_registerName("getUrl");
            if ([obj respondsToSelector:s1]) {
                id u = ((id (*)(id, SEL))objc_msgSend)(obj, s1);
                DYFallbackCollect(u, out, depth + 1);
            }
        } @catch (__unused NSException *e) {}
        } // looksPlayer
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id x in (NSArray *)obj) DYFallbackCollect(x, out, depth + 1);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(__unused id k, id v, __unused BOOL *stop) {
            DYFallbackCollect(v, out, depth + 1);
        }];
        return;
    }
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            // Douyin / Aweme model graph
            @"awemeModel", @"aweme", @"currentAweme", @"playingAweme", @"model",
            @"playAddr", @"playAddrModel", @"playAddrH264", @"playAddrLowbr",
            @"playAddrBytevc1", @"downloadAddr", @"downloadAddrModel",
            @"originDownloadAddr", @"downloadURL", @"playURL",
            @"urlList", @"url_list", @"originURLList", @"originUrlList",
            @"bitRate", @"bit_rate", @"bitRateList", @"bit_rate_list",
            @"playAddrList", @"downloadAddrList", @"videoBitRateList",
            @"h264DownloadAddr", @"h265DownloadAddr", @"HDRBitRateList",
            @"statusModel", @"shareInfo", @"interactionContext",
            @"url", @"urlString", @"imageUrl", @"imageURL", @"image_url",
            @"originUrl", @"originalUrl", @"origin_url", @"original_url",
            @"url_size_large", @"url_default", @"urlDefault", @"urlSizeLarge",
            @"largeUrl", @"veryLargeImageUrl", @"originImageUrl", @"originImgUrl",
            @"info_list", @"infoList", @"urlInfoList", @"url_info_list",
            @"originImgInfo", @"imageInfo", @"image_list", @"url_multi",
            @"livePhotoUrl", @"live_photo_url", @"fileid", @"fileId",
            @"origin_img", @"originImg", @"url_trans", @"currentURL",
            @"imageList", @"images", @"media", @"noteImage", @"noteImageInfo",
            // video
            @"videoURL", @"videoUrl", @"video_url", @"videoUrlString", @"videoURLString",
            @"videoSourceUrl", @"videoSourceURL", @"download_addr", @"downloadAddr",
            @"originVideoURL", @"orginVideoURL", @"originalVideoURL", @"userOriginVideo",
            @"fallbackVideoUrl", @"mediaURL", @"mediaUrl", @"media_url",
            @"currentVideoURL", @"videoStreamingList", @"streamingList",
            @"h264UrlInfo", @"hdrUrlInfo", @"urlInfo", @"multiStreamingUrlInfoList",
            @"video", @"videoInfo", @"videoModel", @"player", @"playerItem",
            @"note", @"noteModel", @"viewModel", @"data", @"item",
            @"awemeModel", @"aweme", @"currentAweme", @"playingAweme",
            @"playAddr", @"downloadAddr", @"videoModel"
        ];
    });
    for (NSString *k in keys) {
        @try {
            if (![obj respondsToSelector:NSSelectorFromString(k)]) continue;
            DYFallbackCollect([obj valueForKey:k], out, depth + 1);
        } @catch (__unused NSException *e) {}
    }
}

static NSInteger DYFallbackURLScore(NSString *u) {
    if (u.length == 0) return -10000;
    NSString *l = u.lowercaseString;
    NSInteger s = (NSInteger)u.length / 50;
    BOOL isVideo = DYFallbackIsVideoURL(u);
    BOOL isImage = DYFallbackIsImageURL(u);
    if (isVideo) s += 80;
    if (isImage && !isVideo) s -= 40;

    // === Quality source class (most important) ===
    // Official download / origin >> adaptive in-app play stream
    BOOL isDownload = [l containsString:@"download_addr"] || [l containsString:@"downloadaddr"] ||
        [l containsString:@"origin_download"] || [l containsString:@"origindownload"] ||
        [l containsString:@"download_url"] || [l containsString:@"downloadurl"] ||
        [l containsString:@"/download/"] || [l containsString:@"downloadaddr"];
    BOOL isOrigin = [l containsString:@"origin_download"] || [l containsString:@"origindownload"] ||
        [l containsString:@"originurl"] || [l containsString:@"origin_url"] ||
        ([l containsString:@"origin"] && [l containsString:@"download"]);
    if (isOrigin) s += 220;
    else if (isDownload) s += 180;
    else if ([l containsString:@"download"]) s += 70;

    // play stream is OK fallback but usually ABR / not original
    if ([l containsString:@"play_addr"] || [l containsString:@"playaddr"]) s += 15;
    if ([l containsString:@"/aweme/v1/play/"] || [l containsString:@"/aweme/v1/play?"]) s += 35;
    if ([l containsString:@"/aweme/v1/play"] && ![l containsString:@"playwm"]) s += 25;
    // Adaptive / low ladders often used by the on-screen player
    if ([l containsString:@"lowbr"] || [l containsString:@"low_br"] ||
        [l containsString:@"playaddrlow"] || [l containsString:@"play_addr_low"] ||
        [l containsString:@"adapt"] || [l containsString:@"abr"] ||
        [l containsString:@"_ld"] || [l containsString:@"_sd"]) s -= 90;
    if ([l containsString:@"360p"] || [l containsString:@"480p"] ||
        [l containsString:@"540p"] || [l containsString:@"540x"] ||
        [l containsString:@"x540"] || [l containsString:@"x480"] ||
        [l containsString:@"x360"]) s -= 100;
    if ([l containsString:@"720p"] || [l containsString:@"x720"] || [l containsString:@"720x"]) s += 35;
    if ([l containsString:@"1080"] || [l containsString:@"x1080"] || [l containsString:@"1080p"]) s += 95;
    if ([l containsString:@"1440"] || [l containsString:@"2k"] || [l containsString:@"x1440"]) s += 120;
    if ([l containsString:@"2160"] || [l containsString:@"4k"] || [l containsString:@"x2160"]) s += 150;

    // bitrate hints in query (Douyin often has br= / bt= kbps-ish)
    NSRegularExpression *brRe = [NSRegularExpression regularExpressionWithPattern:@"(?:^|[?&_])br=(\\d+)" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *brm = [brRe firstMatchInString:l options:0 range:NSMakeRange(0, l.length)];
    if (brm && brm.numberOfRanges > 1) {
        NSInteger br = [[l substringWithRange:[brm rangeAtIndex:1]] integerValue];
        if (br >= 4000) s += 110;
        else if (br >= 2500) s += 80;
        else if (br >= 1500) s += 45;
        else if (br >= 800) s += 10;
        else if (br > 0 && br < 500) s -= 60;
    }
    // codec: h265/bytevc1 often higher quality at same size; still prefer download class above
    if ([l containsString:@"bytevc1"] || [l containsString:@"h265"] ||
        [l containsString:@"hevc"] || [l containsString:@"h.265"]) s += 18;
    if ([l containsString:@"hdr"]) s += 25;

    // Hard penalty for watermark play URLs
    if ([l containsString:@"playwm"] || [l containsString:@"play_wm"] ||
        [l containsString:@"watermark=1"] || [l containsString:@"watermark=true"] ||
        [l containsString:@"&wm=1"] || [l containsString:@"?wm=1"] ||
        [l containsString:@"with_watermark"] || [l containsString:@"withwatermark"]) s -= 160;
    if ([l containsString:@"nwm"] || [l containsString:@"no_watermark"] ||
        [l containsString:@"nowm"] || [l containsString:@"without_watermark"] ||
        [l containsString:@"withoutwatermark"] || [l containsString:@"no-watermark"] ||
        [l containsString:@"watermark=0"] || [l containsString:@"wm=0"]) s += 80;

    if ([l containsString:@"origin"] || [l containsString:@"original"]) s += 25;
    if ([l containsString:@".mp4"] || [l containsString:@".mov"]) s += 20;
    if ([l containsString:@".m3u8"] || [l containsString:@"dash"] || [l containsString:@"m4s"]) s -= 500;

    // Cover / image hosts
    if ([l containsString:@"cover"] || [l containsString:@"avatar"] ||
        [l containsString:@"thumb"] || [l containsString:@"byteimg"] ||
        [l containsString:@"douyinpic"] || [l containsString:@"~tplv-"] ||
        [l containsString:@"icon"] || [l containsString:@"head"]) s -= 80;

    // Local cache: useful fallback, but often ABR already-transcoded play file
    if ([l hasPrefix:@"file:"]) s += 25;
    if ([l hasPrefix:@"https://"]) s += 2;
    return s;
}

// Expand candidates: strip watermark play endpoints so we try no-wm first.
static NSArray<NSString *> *DYNoWatermarkURLVariants(NSString *url) {
    if (url.length == 0) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    void (^add)(NSString *) = ^(NSString *u) {
        if (u.length == 0) return;
        for (NSString *e in out) { if ([e isEqualToString:u]) return; }
        [out addObject:u];
    };
    add(url);
    NSString *u = url;
    // playwm -> play (classic Douyin open API)
    if ([u.lowercaseString containsString:@"playwm"]) {
        NSString *v = [u stringByReplacingOccurrencesOfString:@"playwm" withString:@"play"
                                                       options:NSCaseInsensitiveSearch
                                                         range:NSMakeRange(0, u.length)];
        add(v);
    }
    // query param cleanups
    NSURLComponents *comp = [NSURLComponents componentsWithString:u];
    if (comp) {
        NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
        BOOL changed = NO;
        for (NSURLQueryItem *it in comp.queryItems ?: @[]) {
            NSString *name = it.name.lowercaseString ?: @"";
            if ([name isEqualToString:@"watermark"] || [name isEqualToString:@"wm"] ||
                [name isEqualToString:@"logo"] || [name isEqualToString:@"with_watermark"]) {
                changed = YES;
                continue; // drop
            }
            [items addObject:it];
        }
        // force watermark=0 if host looks like aweme play
        NSString *hostPath = [NSString stringWithFormat:@"%@%@", comp.host ?: @"", comp.path ?: @""].lowercaseString;
        if ([hostPath containsString:@"aweme"] || [hostPath containsString:@"douyin"] ||
            [hostPath containsString:@"snssdk"] || [hostPath containsString:@"iesdouyin"]) {
            [items addObject:[NSURLQueryItem queryItemWithName:@"watermark" value:@"0"]];
            changed = YES;
        }
        if (changed) {
            comp.queryItems = items;
            if (comp.string.length) add(comp.string);
        }
    }
    // common string replacements
    NSArray *pairs = @[
        @[@"watermark=1", @"watermark=0"],
        @[@"watermark=true", @"watermark=0"],
        @[@"&wm=1", @"&wm=0"],
        @[@"?wm=1", @"?wm=0"],
        @[@"/playwm/", @"/play/"],
        @[@"/playwm?", @"/play?"],
    ];
    for (NSArray *p in pairs) {
        if ([u.lowercaseString containsString:[p[0] lowercaseString]]) {
            NSString *v = [u stringByReplacingOccurrencesOfString:p[0] withString:p[1]
                                                          options:NSCaseInsensitiveSearch
                                                            range:NSMakeRange(0, u.length)];
            add(v);
        }
    }
    return out;
}

static BOOL DYFallbackDataLooksPlaylist(NSData *data) {
    if (data.length < 7) return NO;
    NSUInteger n = MIN((NSUInteger)data.length, (NSUInteger)96);
    NSString *head = [[NSString alloc] initWithBytes:data.bytes length:n encoding:NSUTF8StringEncoding];
    if (!head) return NO;
    NSString *t = [head stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [t hasPrefix:@"#EXTM3U"] || [t containsString:@"#EXT-X-"];
}

static BOOL DYFallbackVerifyVideoAssetId(NSString *localId) {
    if (localId.length == 0) return NO;
    @try {
        PHFetchResult<PHAsset *> *r = [PHAsset fetchAssetsWithLocalIdentifiers:@[localId] options:nil];
        PHAsset *a = r.firstObject;
        if (!a) {
            // placeholder id is still a strong success signal if Photos reported success
            return localId.length > 0;
        }
        return a.mediaType == PHAssetMediaTypeVideo;
    } @catch (__unused NSException *e) {
        return localId.length > 0;
    }
}

static void DYFallbackPhotosWriteVideo(NSString *path, void (^done)(BOOL, NSError *)) {
    __block NSString *localId = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetChangeRequest *req =
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:[NSURL fileURLWithPath:path]];
        localId = req.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
        NSLog(@"[DouyinSave] photos write video success=%d id=%@ err=%@", (int)success, localId, error);
        BOOL really = success && DYFallbackVerifyVideoAssetId(localId);
        if (really) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(YES, nil); });
            return;
        }
        __block NSString *localId2 = nil;
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
            [req addResourceWithType:PHAssetResourceTypeVideo
                              fileURL:[NSURL fileURLWithPath:path]
                              options:nil];
            localId2 = req.placeholderForCreatedAsset.localIdentifier;
        } completionHandler:^(BOOL ok2, NSError *e2) {
            NSLog(@"[DouyinSave] photos resource write ok=%d id=%@ err=%@", (int)ok2, localId2, e2);
            BOOL really2 = ok2 && DYFallbackVerifyVideoAssetId(localId2);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (done) done(really2, really2 ? nil : (e2 ?: error ?:
                    [NSError errorWithDomain:@"DouyinSave" code:3302
                                    userInfo:@{NSLocalizedDescriptionKey: @"Photos rejected video"}]));
            });
        }];
    }];
}

static void DYFallbackUISaveVideo(NSString *path, void (^done)(BOOL, NSError *)) {
    if (!UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(path)) {
        if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:7
                              userInfo:@{NSLocalizedDescriptionKey: @"UIVideo incompatible"}]);
        return;
    }
    // Use Photos path after ensuring compatibility; UISave lacks clean block API in pure C
    DYFallbackPhotosWriteVideo(path, done);
}

static void DYFallbackExportVideoThen(NSString *path, void (^done)(NSString *outPath, NSError *err)) {
    NSURL *inURL = [NSURL fileURLWithPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:inURL options:@{
        AVURLAssetPreferPreciseDurationAndTimingKey: @YES
    }];
    NSArray *presets = [AVAssetExportSession exportPresetsCompatibleWithAsset:asset];
    NSString *preset = nil;
    // Prefer no re-encode / max quality. NEVER pick Medium/Low before Highest.
    for (NSString *p in @[AVAssetExportPresetPassthrough,
                          AVAssetExportPresetHighestQuality,
                          AVAssetExportPreset1920x1080,
                          AVAssetExportPreset1280x720,
                          AVAssetExportPresetMediumQuality,
                          AVAssetExportPresetLowQuality]) {
        if ([presets containsObject:p]) { preset = p; break; }
    }
    if (!preset && presets.count) preset = presets.firstObject;
    if (!preset) {
        if (done) done(nil, [NSError errorWithDomain:@"DouyinSave" code:8
                               userInfo:@{NSLocalizedDescriptionKey: @"no export preset"}]);
        return;
    }
    AVAssetExportSession *ex = [AVAssetExportSession exportSessionWithAsset:asset presetName:preset];
    if (!ex) {
        if (done) done(nil, [NSError errorWithDomain:@"DouyinSave" code:9
                               userInfo:@{NSLocalizedDescriptionKey: @"export session nil"}]);
        return;
    }
    BOOL pass = [preset isEqualToString:AVAssetExportPresetPassthrough];
    NSString *ext = pass ? (path.pathExtension.length ? path.pathExtension : @"mp4") : @"mp4";
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"dy_exp_%@.%@", NSUUID.UUID.UUIDString, ext]];
    [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
    ex.outputURL = [NSURL fileURLWithPath:outPath];
    NSArray *types = ex.supportedFileTypes;
    if ([types containsObject:AVFileTypeMPEG4]) {
        ex.outputFileType = AVFileTypeMPEG4;
    } else if ([types containsObject:AVFileTypeQuickTimeMovie]) {
        ex.outputFileType = AVFileTypeQuickTimeMovie;
    } else if (types.count) {
        ex.outputFileType = types.firstObject;
    } else {
        if (done) done(nil, [NSError errorWithDomain:@"DouyinSave" code:10
                               userInfo:@{NSLocalizedDescriptionKey: @"no export file type"}]);
        return;
    }
    ex.shouldOptimizeForNetworkUse = NO; // keep quality
    NSLog(@"[DouyinSave] export start preset=%@ types=%@", preset, types);
    [ex exportAsynchronouslyWithCompletionHandler:^{
        if (ex.status == AVAssetExportSessionStatusCompleted &&
            [[NSFileManager defaultManager] fileExistsAtPath:outPath]) {
            NSLog(@"[DouyinSave] export ok %@", outPath);
            if (done) done(outPath, nil);
            return;
        }
        NSLog(@"[DouyinSave] export fail status=%ld err=%@", (long)ex.status, ex.error);
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
        if (done) done(nil, ex.error ?: [NSError errorWithDomain:@"DouyinSave" code:11
            userInfo:@{NSLocalizedDescriptionKey: @"export failed"}]);
    }];
}

static void DYFallbackSaveVideoFile(NSString *path, void (^done)(BOOL, NSError *)) {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:5
                              userInfo:@{NSLocalizedDescriptionKey: @"video file missing"}]);
        return;
    }
    unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
    NSData *head = nil;
    {
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (fh) {
            @try { head = [fh readDataOfLength:96]; } @catch (__unused NSException *e) {}
            @try { [fh closeFile]; } @catch (__unused NSException *e) {}
        }
    }
    if (head.length >= 7 && DYFallbackDataLooksPlaylist(head)) {
        if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:12
                              userInfo:@{NSLocalizedDescriptionKey: @"HLS m3u8 playlist (need mp4)"}]);
        return;
    }
    // tiny / empty
    if (sz < 1024) {
        if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:6
                              userInfo:@{NSLocalizedDescriptionKey: @"video too small"}]);
        return;
    }
    // ensure extension Photos likes
    NSString *usePath = path;
    NSString *ext = path.pathExtension.lowercaseString;
    NSString *fixed = nil;
    if (!( [ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"] )) {
        fixed = [NSTemporaryDirectory() stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"dy_vidfix_%@.mp4", NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager] removeItemAtPath:fixed error:nil];
        if ([[NSFileManager defaultManager] copyItemAtPath:path toPath:fixed error:nil]) {
            usePath = fixed;
        }
    }

    DYFallbackAuthThen(^(BOOL granted) {
        if (!granted) {
            if (fixed) [[NSFileManager defaultManager] removeItemAtPath:fixed error:nil];
            if (done) done(NO, [NSError errorWithDomain:@"DouyinSave" code:2
                                  userInfo:@{NSLocalizedDescriptionKey: @"album permission denied"}]);
            return;
        }

        void (^finish)(BOOL, NSError *) = ^(BOOL ok, NSError *e) {
            if (fixed) [[NSFileManager defaultManager] removeItemAtPath:fixed error:nil];
            if (done) done(ok, e);
        };

        // v1.3 Path A: direct Photos write first (export was OOM/watchdog crash source)
        DYFallbackPhotosWriteVideo(usePath, ^(BOOL ok, NSError *e) {
            if (ok) { finish(YES, nil); return; }
            NSLog(@"[DouyinSave] direct photos failed: %@ - try export", e);
            DYFallbackToast(@"正在转码视频…");
            // Path B: re-export progressive mp4 then Photos (CDN fMP4 / 3302)
            DYFallbackExportVideoThen(usePath, ^(NSString *outPath, NSError *expErr) {
                if (outPath.length) {
                    DYFallbackPhotosWriteVideo(outPath, ^(BOOL ok2, NSError *e2) {
                        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
                        if (ok2) { finish(YES, nil); return; }
                        NSLog(@"[DouyinSave] photos after export failed: %@", e2);
                        DYFallbackUISaveVideo(usePath, finish);
                    });
                    return;
                }
                NSLog(@"[DouyinSave] export unavailable: %@", expErr);
                DYFallbackUISaveVideo(usePath, ^(BOOL ok3, NSError *e3) {
                    finish(ok3, ok3 ? nil : (e3 ?: e ?: expErr));
                });
            });
        });
    });
}

static BOOL DYFallbackDataLooksVideo(NSData *data, NSString *urlString, NSString *mime) {
    // UIImage can decode HEIC/AVIF/JPEG/PNG/WebP; if so, never treat as video.
    if (data.length >= 32 && [UIImage imageWithData:data] != nil) {
        return NO;
    }
    NSString *m = mime.lowercaseString ?: @"";
    if ([m hasPrefix:@"image/"] ||
        [m containsString:@"jpeg"] || [m containsString:@"png"] ||
        [m containsString:@"webp"] || [m containsString:@"heic"] ||
        [m containsString:@"heif"] || [m containsString:@"avif"] ||
        [m containsString:@"gif"]) {
        return NO;
    }
    if ([m hasPrefix:@"video/"] ||
        [m containsString:@"mp4"] || [m containsString:@"mpeg"] ||
        [m containsString:@"quicktime"] || [m containsString:@"x-m4v"]) {
        return YES;
    }
    if (data.length >= 12) {
        const unsigned char *b = data.bytes;
        // ISO BMFF: ....ftypXXXX  (HEIC/AVIF also use ftyp!)
        if (b[4] == 'f' && b[5] == 't' && b[6] == 'y' && b[7] == 'p') {
            char brand[5] = {0};
            brand[0] = (char)b[8];
            brand[1] = (char)b[9];
            brand[2] = (char)b[10];
            brand[3] = (char)b[11];
            NSString *br = [[NSString stringWithUTF8String:brand] lowercaseString];
            if ([br isEqualToString:@"heic"] || [br isEqualToString:@"heix"] ||
                [br isEqualToString:@"hevc"] || [br isEqualToString:@"hevx"] ||
                [br isEqualToString:@"mif1"] || [br isEqualToString:@"msf1"] ||
                [br isEqualToString:@"avif"] || [br isEqualToString:@"avis"] ||
                [br isEqualToString:@"miaf"] || [br isEqualToString:@"mihb"]) {
                return NO;
            }
            if ([br isEqualToString:@"isom"] || [br isEqualToString:@"iso2"] ||
                [br isEqualToString:@"iso3"] || [br isEqualToString:@"iso4"] ||
                [br isEqualToString:@"iso5"] || [br isEqualToString:@"iso6"] ||
                [br isEqualToString:@"mp41"] || [br isEqualToString:@"mp42"] ||
                [br isEqualToString:@"avc1"] || [br isEqualToString:@"dash"] ||
                [br isEqualToString:@"msdh"] || [br isEqualToString:@"m4v "] ||
                [br isEqualToString:@"qt  "] || [br hasPrefix:@"mp4"]) {
                return YES;
            }
        }
    }
    // With enough payload bytes, URL alone must NOT force video (covers mis-scored)
    if (data.length >= 64) return NO;
    // tiny/empty probe only: allow URL heuristic
    if (DYFallbackIsVideoURL(urlString)) return YES;
    return NO;
}

static BOOL DYFallbackDataLooksTextPayload(NSData *data) {
    if (data.length < 8) return NO;
    NSUInteger n = MIN((NSUInteger)data.length, (NSUInteger)64);
    const unsigned char *b = data.bytes;
    NSUInteger i = 0;
    while (i < n && (b[i] == 0xEF || b[i] == 0xBB || b[i] == 0xBF ||
                     b[i] == ' ' || b[i] == '\n' || b[i] == '\r' || b[i] == '\t')) i++;
    if (i >= n) return NO;
    unsigned char c = b[i];
    if (c == '{' || c == '[' || c == '<') return YES;
    NSString *head = [[NSString alloc] initWithBytes:b + i length:MIN((NSUInteger)24, n - i)
                                            encoding:NSASCIIStringEncoding];
    if (!head) return NO;
    NSString *hl = head.lowercaseString;
    return [hl hasPrefix:@"error"] || [hl hasPrefix:@"forbidden"] ||
           [hl hasPrefix:@"denied"] || [hl hasPrefix:@"not found"];
}

static BOOL DYFallbackFileLooksPlayableVideo(NSString *path) {
    if (path.length == 0) return NO;
    unsigned long long sz = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] fileSize];
    if (sz < 32 * 1024) return NO;
    // only map first 64KB — never load whole multi-MB file for probe
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *probe = nil;
    if (fh) {
        @try { probe = [fh readDataOfLength:64 * 1024]; } @catch (__unused NSException *e) {}
        @try { [fh closeFile]; } @catch (__unused NSException *e) {}
    }
    if (!probe) {
        probe = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
        if (probe.length > 64 * 1024) probe = [probe subdataWithRange:NSMakeRange(0, 64 * 1024)];
    }
    if (probe.length >= 8 && DYFallbackDataLooksTextPayload(probe)) return NO;
    BOOL magicOK = (probe.length >= 32 && DYFallbackDataLooksVideo(probe, path, @"video/mp4"));
    // v1.3: do NOT create AVURLAsset here (can hang/crash on partial CDN files / main thread)
    return magicOK && sz > 48 * 1024;
}

static void DYFallbackDownloadOneVideo(NSString *urlString, void (^done)(BOOL ok, NSString *msg));
static void DYFallbackDownloadVideosTry(NSArray<NSString *> *urls, NSUInteger idx);
static void DYFallbackDownloadAndSaveImage(NSString *urlString);

static void DYFallbackDownloadAndSave(NSString *urlString) {
    if (!urlString.length) return;
    DYFallbackDownloadVideosTry(@[urlString], 0);
}

static void DYFallbackDownloadVideosTry(NSArray<NSString *> *urls, NSUInteger idx) {
    if (!urls.count) {
        DYFallbackToast(@"\u672a\u627e\u5230\u53ef\u4e0b\u8f7d\u7684\u89c6\u9891\u5730\u5740");
        return;
    }
    if (idx >= urls.count) {
        DYFallbackToast([NSString stringWithFormat:@"\u89c6\u9891\u4fdd\u5b58\u5931\u8d25\uff08\u5df2\u5c1d\u8bd5 %lu \u4e2a\u5730\u5740\uff09",
                          (unsigned long)urls.count]);
        return;
    }
    NSString *urlString = urls[idx];
    NSLog(@"[DouyinSave] try video[%lu/%lu] score=%ld %@",
          (unsigned long)(idx + 1), (unsigned long)urls.count,
          (long)DYFallbackURLScore(urlString),
          urlString.length > 160 ? [[urlString substringToIndex:160] stringByAppendingString:@"..."] : urlString);
    if (idx == 0) {
        DYFallbackToast(@"\u6b63\u5728\u4e0b\u8f7d\u9ad8\u6e05\u89c6\u9891\u2026");
    } else {
        DYFallbackToast([NSString stringWithFormat:@"\u6362\u6e90\u91cd\u8bd5 %lu/%lu\u2026",
                          (unsigned long)(idx + 1), (unsigned long)urls.count]);
    }
    DYFallbackDownloadOneVideo(urlString, ^(BOOL ok, NSString *msg) {
        if (ok) {
            DYFallbackToast(msg.length ? msg : @"\u2705\u89c6\u9891\u5df2\u4fdd\u5b58\u5230\u76f8\u518c");
            return;
        }
        NSLog(@"[DouyinSave] video try fail[%lu]: %@", (unsigned long)idx, msg ?: @"?");
        DYFallbackDownloadVideosTry(urls, idx + 1);
    });
}


static void DYFallbackDownloadOneVideo(NSString *urlString, void (^done)(BOOL ok, NSString *msg)) {
    if (!urlString.length) {
        if (done) done(NO, @"empty url");
        return;
    }
    BOOL wantVideo = DYFallbackIsVideoURL(urlString) || [urlString hasPrefix:@"file:"] ||
                     [urlString hasPrefix:@"/"];
    NSLog(@"[DouyinSave] fallback GET %@ video=%d", urlString, (int)wantVideo);

    void (^saveLocalPath)(NSString *) = ^(NSString *path) {
        if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            if (done) done(NO, @"file missing");
            return;
        }
        // v1.3: only probe head — never map multi-MB video into memory
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        NSData *probe = nil;
        if (fh) {
            @try { probe = [fh readDataOfLength:64 * 1024]; } @catch (__unused NSException *e) {}
            @try { [fh closeFile]; } @catch (__unused NSException *e) {}
        }
        if (probe.length && DYFallbackDataLooksTextPayload(probe)) {
            if (done) done(NO, @"local file is text");
            return;
        }
        if (!DYFallbackFileLooksPlayableVideo(path)) {
            if (done) done(NO, @"local file not video");
            return;
        }
        DYFallbackSaveVideoFile(path, ^(BOOL ok, NSError *e) {
            if (done) done(ok, ok ? @"✅ 视频已保存到相册" :
                           (e.localizedDescription ?: @"photos write fail"));
        });
    };

    if ([urlString hasPrefix:@"file:"]) {
        NSURL *fu = [NSURL URLWithString:urlString];
        if (fu.path.length) { saveLocalPath(fu.path); return; }
    }
    if ([urlString hasPrefix:@"/"] && [[NSFileManager defaultManager] fileExistsAtPath:urlString]) {
        saveLocalPath(urlString);
        return;
    }
    if ([urlString.lowercaseString containsString:@".m3u8"]) {
        if (done) done(NO, @"m3u8 unsupported");
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (done) done(NO, @"bad url");
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:120];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Aweme 38.7.0"
forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"https://www.douyin.com" forHTTPHeaderField:@"Origin"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];

    NSMutableArray *allCookies = [NSMutableArray array];
    @try {
        NSArray *c1 = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookiesForURL:url];
        if (c1.count) [allCookies addObjectsFromArray:c1];
        NSArray *c2 = [[NSHTTPCookieStorage sharedHTTPCookieStorage]
                       cookiesForURL:[NSURL URLWithString:@"https://www.douyin.com/"]];
        for (NSHTTPCookie *c in c2) {
            BOOL exists = NO;
            for (NSHTTPCookie *e in allCookies) {
                if ([e.name isEqualToString:c.name] && [e.domain isEqualToString:c.domain]) {
                    exists = YES; break;
                }
            }
            if (!exists) [allCookies addObject:c];
        }
    } @catch (__unused NSException *e) {}
    if (allCookies.count) {
        NSDictionary *hdrs = [NSHTTPCookie requestHeaderFieldsWithCookies:allCookies];
        NSString *cookie = hdrs[@"Cookie"];
        if (cookie.length) [req setValue:cookie forHTTPHeaderField:@"Cookie"];
    }

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.HTTPShouldSetCookies = YES;
    cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session downloadTaskWithRequest:req completionHandler:^(NSURL *location, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        NSInteger code = [http isKindOfClass:[NSHTTPURLResponse class]] ? http.statusCode : 0;
        NSString *mime = http.MIMEType ?: @"";
        NSLog(@"[DouyinSave] download resp %ld mime=%@ err=%@ loc=%@",
              (long)code, mime, err, location.path);
        if (err || !location) {
            if (done) done(NO, err.localizedDescription ?: @"empty");
            return;
        }
        if (code >= 400) {
            if (done) done(NO, [NSString stringWithFormat:@"HTTP %ld", (long)code]);
            return;
        }
        NSString *ml = mime.lowercaseString;
        if ([ml hasPrefix:@"text/"] || [ml containsString:@"json"] || [ml containsString:@"html"]) {
            if (done) done(NO, [NSString stringWithFormat:@"bad mime %@", mime]);
            return;
        }

        NSData *probe = [NSData dataWithContentsOfURL:location options:NSDataReadingMappedIfSafe error:nil];
        unsigned long long sz = (unsigned long long)probe.length;
        @try {
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil];
            if (attr.fileSize > sz) sz = attr.fileSize;
        } @catch (__unused NSException *e) {}

        if (probe.length >= 8 && (DYFallbackDataLooksPlaylist(probe) || DYFallbackDataLooksTextPayload(probe))) {
            if (done) done(NO, @"got playlist/text not mp4");
            return;
        }

        NSString *ext = @"mp4";
        NSString *pe = location.pathExtension.lowercaseString;
        if ([pe isEqualToString:@"mov"] || [pe isEqualToString:@"m4v"] || [pe isEqualToString:@"mp4"]) ext = pe;
        else if ([ml containsString:@"quicktime"]) ext = @"mov";

        NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [NSString stringWithFormat:@"dy_vid_%@.%@", NSUUID.UUID.UUIDString, ext]];
        [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
        NSError *cpErr = nil;
        if (![[NSFileManager defaultManager] copyItemAtURL:location toURL:[NSURL fileURLWithPath:tmp] error:&cpErr]) {
            if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:tmp] error:&cpErr]) {
                if (done) done(NO, cpErr.localizedDescription ?: @"copy fail");
                return;
            }
        }

        if (!DYFallbackFileLooksPlayableVideo(tmp)) {
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            NSLog(@"[DouyinSave] not playable video mime=%@ bytes=%llu", mime, sz);
            if (done) done(NO, @"content is not playable video");
            return;
        }

        // Reject obvious low-ladder streams so caller can try next (download/origin) URL
        {
            double sec = 0;
            @try {
                AVURLAsset *a = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:tmp] options:nil];
                sec = CMTimeGetSeconds(a.duration);
            } @catch (__unused NSException *e) {}
            if (sec > 2.5 && sec < 600) {
                double kbps = (sz * 8.0) / (sec * 1000.0);
                // Mobile feed play often ~400-900kbps; original download usually >>1500
                if (sz < 500ull * 1024ull || kbps < 700.0) {
                    NSLog(@"[DouyinSave] reject low quality bytes=%llu sec=%.1f kbps=%.0f",
                          sz, sec, kbps);
                    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
                    if (done) done(NO, @"low quality stream");
                    return;
                }
            } else if (sz < 350ull * 1024ull) {
                NSLog(@"[DouyinSave] reject tiny video bytes=%llu", sz);
                [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
                if (done) done(NO, @"tiny video");
                return;
            }
        }

        NSLog(@"[DouyinSave] video file ready bytes=%llu", sz);
        DYFallbackSaveVideoFile(tmp, ^(BOOL ok, NSError *e) {
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
            if (done) done(ok, ok ? @"\u2705\u89c6\u9891\u5df2\u4fdd\u5b58\u5230\u76f8\u518c" :
                           (e.localizedDescription ?: @"photos failed"));
        });

    }] resume];
}

static void DYFallbackDownloadAndSaveImage(NSString *urlString) {
    if (!urlString.length) return;
    DYFallbackToast(@"正在下载图片…");
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { DYFallbackToast(@"URL 无效"); return; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:30];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 Aweme 38.7.0"
forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.douyin.com/" forHTTPHeaderField:@"Referer"];
    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        NSInteger code = [http isKindOfClass:[NSHTTPURLResponse class]] ? http.statusCode : 0;
        if (err || data.length < 32 || code >= 400) {
            DYFallbackToast([NSString stringWithFormat:@"图片下载失败: %@",
                              err.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)code]]);
            return;
        }
        DYFallbackSaveData(data, ^(BOOL ok, NSError *e) {
            DYFallbackToast(ok ? @"✅ 图片已保存到相册" :
                             [NSString stringWithFormat:@"保存失败: %@", e.localizedDescription ?: @"?"]);
        });
    }] resume];
}

static BOOL DYViewClassLooksMedia(UIView *v) {
    if (!v) return NO;
    const char *cn = object_getClassName(v);
    if (!cn) return NO;
    return strstr(cn, "Player") || strstr(cn, "Video") || strstr(cn, "Aweme") ||
           strstr(cn, "Feed") || strstr(cn, "Play") || strstr(cn, "Media") ||
           strstr(cn, "IES") || strstr(cn, "TTVideo") || strstr(cn, "Image") ||
           strstr(cn, "Photo") || strstr(cn, "Note") || strstr(cn, "Cell");
}

static void DYFallbackCollectFromView(UIView *root, NSMutableSet<NSString *> *set) {
    UIView *v = root;
    for (int i = 0; i < 10 && v; i++, v = v.superview) {
        if (!DYViewClassLooksMedia(v) && ![v isKindOfClass:[UIImageView class]]) {
            continue;
        }
        NSArray *keys;
        if ([v isKindOfClass:[UIImageView class]]) {
            keys = @[@"imageURL", @"imageUrl", @"url", @"sd_imageURL", @"yy_imageURL",
                     @"awemeModel", @"model", @"downloadAddr", @"playAddr"];
        } else {
            keys = @[@"awemeModel", @"aweme", @"currentAweme", @"playingAweme",
                     @"playAddr", @"downloadAddr", @"playAddrModel", @"downloadAddrModel",
                     @"videoURL", @"videoUrl", @"player", @"playerItem", @"videoModel",
                     @"video", @"model", @"viewModel", @"context", @"interactionContext"];
        }
        for (NSString *k in keys) {
            @try {
                if (![v respondsToSelector:NSSelectorFromString(k)]) continue;
                DYFallbackCollect([v valueForKey:k], set, 0);
            } @catch (__unused NSException *e) {}
        }
    }
}

static UIImage *DYFallbackBestImageNear(UIView *view) {
    UIView *v = view;
    for (int i = 0; i < 14 && v; i++, v = v.superview) {
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImage *img = ((UIImageView *)v).image;
            if (img.size.width > 48 && img.size.height > 48) return img;
        }
    }
    return nil;
}

static void DYFallbackWalkImageViews(UIView *view, NSMutableArray<UIImageView *> *out) {
    if (!view || view.hidden || view.alpha < 0.05) return;
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *iv = (UIImageView *)view;
        if (iv.image && iv.image.size.width > 48 && iv.image.size.height > 48 &&
            iv.bounds.size.width > 48 && iv.bounds.size.height > 48) {
            [out addObject:iv];
        }
    }
    for (UIView *sub in view.subviews) {
        DYFallbackWalkImageViews(sub, out);
    }
}

static UIImageView *DYFallbackPickBestImageView(UIWindow *win, CGPoint prefer) {
    NSMutableArray<UIImageView *> *all = [NSMutableArray array];
    DYFallbackWalkImageViews(win, all);
    if (!all.count) return nil;

    UIImageView *best = nil;
    CGFloat bestScore = -1;
    for (UIImageView *iv in all) {
        CGRect r = [iv convertRect:iv.bounds toView:win];
        if (CGRectIsEmpty(r) || r.size.width < 48 || r.size.height < 48) continue;
        // prefer large content near preferred point / screen center
        CGFloat area = r.size.width * r.size.height;
        CGFloat cx = CGRectGetMidX(r), cy = CGRectGetMidY(r);
        CGFloat dx = cx - prefer.x, dy = cy - prefer.y;
        CGFloat dist = sqrt(dx * dx + dy * dy);
        CGFloat score = area - dist * 18.0;
        // penalize very top bars / tiny corner widgets
        if (r.origin.y < 80 && r.size.height < 120) score -= 80000;
        if (score > bestScore) {
            bestScore = score;
            best = iv;
        }
    }
    return best;
}

static void DYFallbackCollectFromResponder(UIResponder *r, NSMutableSet<NSString *> *set) {
    UIResponder *cur = r;
    for (int i = 0; i < 12 && cur; i++, cur = cur.nextResponder) {
        for (NSString *k in @[@"model", @"viewModel", @"awemeModel", @"aweme",
                              @"currentAweme", @"playingAweme", @"note", @"noteModel",
                              @"data", @"item", @"media", @"video", @"videoModel",
                              @"videoInfo", @"player", @"playAddr", @"downloadAddr",
                              @"playAddrModel", @"downloadAddrModel",
                              @"videoURL", @"videoUrl", @"currentVideoURL", @"videoSourceUrl",
                              @"content", @"noteImageInfo", @"mediaModel",
                              @"playerController", @"interactionContext", @"shareContext"]) {
            @try {
                if (![cur respondsToSelector:NSSelectorFromString(k)]) continue;
                DYFallbackCollect([(id)cur valueForKey:k], set, 0);
            } @catch (__unused NSException *e) {}
        }
        for (NSString *path in @[@"player.currentItem", @"player.currentItem.asset",
                                 @"videoPlayer.currentItem", @"playerItem.asset"]) {
            @try {
                id v = [(id)cur valueForKeyPath:path];
                DYFallbackCollect(v, set, 0);
            } @catch (__unused NSException *e) {}
        }
        @try {
            id asset = [(id)cur valueForKeyPath:@"player.currentItem.asset"];
            if ([asset respondsToSelector:@selector(URL)]) {
                DYFallbackCollect([asset valueForKey:@"URL"], set, 0);
            }
        } @catch (__unused NSException *e) {}
    }
}

static void DYFallbackCollectPlayersInView(UIView *root, NSMutableSet<NSString *> *set) {
    if (!root) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger steps = 0;
    while (stack.count && steps < 280) {
        steps++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        @try {
            CALayer *layer = v.layer;
            if ([layer isKindOfClass:[AVPlayerLayer class]]) {
                AVPlayer *pl = [(AVPlayerLayer *)layer player];
                DYFallbackCollect(pl, set, 0);
            }
            // v1.3: only KVC player-ish views (blind valueForKey on every UIView crashes Aweme)
            const char *cn = object_getClassName(v);
            BOOL interesting = cn && (
                strstr(cn, "Player") || strstr(cn, "Video") || strstr(cn, "Aweme") ||
                strstr(cn, "Engine") || strstr(cn, "Feed") || strstr(cn, "Play") ||
                strstr(cn, "IES") || strstr(cn, "TTVideo") || strstr(cn, "Media"));
            if (interesting) {
                for (NSString *k in @[@"player", @"videoPlayer", @"videoEngine", @"ttVideoEngine",
                                      @"awemeModel", @"model", @"context", @"currentAweme",
                                      @"playingAweme", @"videoModel", @"playAddr", @"downloadAddr"]) {
                    @try {
                        if ([v respondsToSelector:NSSelectorFromString(k)]) {
                            DYFallbackCollect([v valueForKey:k], set, 0);
                        }
                    } @catch (__unused NSException *e) {}
                }
            }
        } @catch (__unused NSException *e) {}
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

static UIViewController *DYTopViewController(void) {
    UIWindow *win = DYFallbackKeyWindow();
    if (!win) return nil;
    UIViewController *root = win.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:[UINavigationController class]]) {
        root = ((UINavigationController *)root).visibleViewController ?: root;
    }
    if ([root isKindOfClass:[UITabBarController class]]) {
        root = ((UITabBarController *)root).selectedViewController ?: root;
        if ([root isKindOfClass:[UINavigationController class]]) {
            root = ((UINavigationController *)root).visibleViewController ?: root;
        }
    }
    // drill into child VCs (feed containers)
    NSInteger hops = 0;
    while (root.childViewControllers.count && hops++ < 6) {
        UIViewController *best = nil;
        for (UIViewController *c in root.childViewControllers) {
            if (c.isViewLoaded && c.view.window) { best = c; break; }
        }
        if (!best) best = root.childViewControllers.lastObject;
        if (!best || best == root) break;
        root = best;
        if ([root isKindOfClass:[UINavigationController class]]) {
            root = ((UINavigationController *)root).visibleViewController ?: root;
        }
    }
    return root;
}

// How much of `v` is on-screen / centered inside `container`. Higher = more "current".
static CGFloat DYVisibilityScore(UIView *v, UIView *container) {
    if (!v || !container || v.hidden || v.alpha < 0.02) return -1e9;
    CGRect r = [v convertRect:v.bounds toView:container];
    CGRect bounds = container.bounds;
    if (CGRectIsEmpty(r) || CGRectIsEmpty(bounds)) return -1e9;
    CGRect inter = CGRectIntersection(r, bounds);
    if (CGRectIsEmpty(inter) || inter.size.width < 8 || inter.size.height < 8) return -1e9;
    CGFloat area = inter.size.width * inter.size.height;
    CGFloat cx = CGRectGetMidX(r), cy = CGRectGetMidY(r);
    CGFloat dx = cx - CGRectGetMidX(bounds);
    CGFloat dy = cy - CGRectGetMidY(bounds);
    CGFloat dist = sqrt(dx * dx + dy * dy);
    // Full-screen feed cells: area dominates; slight center bias for mid-swipe
    return area - dist * 24.0;
}

static void DYFallbackCollectCellKeys(UIView *cell, NSMutableSet<NSString *> *set) {
    if (!cell || !set) return;
    for (NSString *k in @[@"awemeModel", @"aweme", @"model", @"viewModel",
                          @"currentAweme", @"playingAweme", @"context",
                          @"video", @"videoModel", @"pageContext",
                          @"playAddr", @"downloadAddr", @"player"]) {
        @try {
            if ([cell respondsToSelector:NSSelectorFromString(k)]) {
                DYFallbackCollect([cell valueForKey:k], set, 0);
            }
        } @catch (__unused NSException *e) {}
    }
    DYFallbackCollectFromView(cell, set);
    DYFallbackCollectFromResponder(cell, set);
}

// v1.5: ONLY the most-visible cell per scroll view (Douyin preloads next/prev)
static void DYFallbackCollectFromScrollViews(UIView *root, NSMutableSet<NSString *> *set) {
    if (!root || !set) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger steps = 0;
    while (stack.count && steps < 220) {
        steps++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)v;
            UITableViewCell *best = nil;
            CGFloat bestScore = -1e9;
            for (UITableViewCell *cell in tv.visibleCells) {
                CGFloat sc = DYVisibilityScore(cell, tv);
                if (sc > bestScore) { bestScore = sc; best = cell; }
            }
            if (best) DYFallbackCollectCellKeys(best, set);
        } else if ([v isKindOfClass:[UICollectionView class]]) {
            UICollectionView *cv = (UICollectionView *)v;
            UICollectionViewCell *best = nil;
            CGFloat bestScore = -1e9;
            for (UICollectionViewCell *cell in cv.visibleCells) {
                CGFloat sc = DYVisibilityScore(cell, cv);
                if (sc > bestScore) { bestScore = sc; best = cell; }
            }
            if (best) DYFallbackCollectCellKeys(best, set);
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
}

// Prefer the single most-centered / actually-playing AVPlayerLayer
static void DYFallbackCollectActivePlayersInView(UIView *root, NSMutableSet<NSString *> *set) {
    if (!root || !set) return;
    UIView *container = root.window ?: root;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    NSInteger steps = 0;
    AVPlayer *bestPlayer = nil;
    UIView *bestEngineView = nil;
    id bestEngine = nil;
    CGFloat bestPlayerScore = -1e9;
    CGFloat bestEngineScore = -1e9;
    while (stack.count && steps < 320) {
        steps++;
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        @try {
            CALayer *layer = v.layer;
            if ([layer isKindOfClass:[AVPlayerLayer class]]) {
                AVPlayer *pl = [(AVPlayerLayer *)layer player];
                if (pl) {
                    CGFloat sc = DYVisibilityScore(v, container);
                    if (pl.rate > 0.01) sc += 500000; // currently playing wins
                    if (pl.currentItem) sc += 50000;
                    if (sc > bestPlayerScore) {
                        bestPlayerScore = sc;
                        bestPlayer = pl;
                    }
                }
            }
            const char *cn = object_getClassName(v);
            if (cn && (strstr(cn, "Player") || strstr(cn, "Video") || strstr(cn, "TTVideo") ||
                       strstr(cn, "IES") || strstr(cn, "Engine") || strstr(cn, "Play"))) {
                for (NSString *k in @[@"player", @"videoPlayer", @"ttPlayer", @"iesPlayer"]) {
                    @try {
                        if (![v respondsToSelector:NSSelectorFromString(k)]) continue;
                        id p = [v valueForKey:k];
                        if (!p) continue;
                        CGFloat sc = DYVisibilityScore(v, container);
                        if ([p isKindOfClass:[AVPlayer class]]) {
                            AVPlayer *ap = (AVPlayer *)p;
                            if (ap.rate > 0.01) sc += 500000;
                            if (ap.currentItem) sc += 50000;
                            if (sc > bestPlayerScore) {
                                bestPlayerScore = sc;
                                bestPlayer = ap;
                            }
                        } else if (sc > bestEngineScore) {
                            bestEngineScore = sc;
                            bestEngineView = v;
                            bestEngine = p;
                        }
                    } @catch (__unused NSException *e) {}
                }
            }
        } @catch (__unused NSException *e) {}
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    // Only the single best player / engine — never all preloaded ones
    if (bestPlayer) {
        DYFallbackCollect(bestPlayer, set, 0);
        @try {
            AVPlayerItem *item = bestPlayer.currentItem;
            if (item) DYFallbackCollect(item, set, 0);
            id asset = item.asset;
            if ([asset isKindOfClass:[AVURLAsset class]]) {
                NSURL *u = [(AVURLAsset *)asset URL];
                if (u.absoluteString.length) [set addObject:u.absoluteString];
            }
        } @catch (__unused NSException *e) {}
    }
    if (bestEngine) {
        DYFallbackCollect(bestEngine, set, 0);
        if (bestEngineView) DYFallbackCollectFromView(bestEngineView, set);
    }
}

static BOOL DYSetHasVideoURL(NSSet<NSString *> *set) {
    for (NSString *u in set) {
        if (DYFallbackIsVideoURL(u) && ![u.lowercaseString containsString:@".m3u8"]) return YES;
    }
    return NO;
}

static void DYFallbackCollectClassNamedModels(id obj, NSMutableSet<NSString *> *set, NSInteger depth) {
    if (!obj || depth > 4 || set.count > 120) return;
    const char *cn = object_getClassName(obj);
    if (!cn) return;
    if (strstr(cn, "AwemeModel") || strstr(cn, "AWEVideoModel") ||
        strstr(cn, "AWEURLModel") || strstr(cn, "VideoModel")) {
        DYFallbackCollect(obj, set, 0);
        for (NSString *k in @[@"video", @"videoModel", @"downloadAddr", @"downloadAddrModel",
                              @"playAddr", @"playAddrModel", @"playAddrH264Model",
                              @"playAddrBytevc1Model", @"originDownloadAddr",
                              @"downloadURL", @"downloadUrl", @"download_url",
                              @"h264URL", @"bytevc1URL", @"playURL", @"playUrl",
                              @"urlList", @"url_list", @"originURLList", @"origin_url_list",
                              @"bitRate", @"bit_rate", @"bitRateList", @"bit_rate_list",
                              @"playAddrList", @"downloadAddrList", @"videoBitRateList",
                              @"h264DownloadAddr", @"h265DownloadAddr"]) {
            @try {
                id v = [obj valueForKey:k];
                if (v) DYFallbackCollect(v, set, depth + 1);
            } @catch (__unused NSException *e) {}
        }
    }
    if ([obj isKindOfClass:[NSArray class]] && depth < 3) {
        NSInteger n = 0;
        for (id x in (NSArray *)obj) {
            if (++n > 30) break;
            DYFallbackCollectClassNamedModels(x, set, depth + 1);
        }
    }
}

static void DYFallbackForceSaveFromView(UIView *view) {
    @try {
    if (!view) {
        DYFallbackToast(@"\u672a\u627e\u5230\u53ef\u4fdd\u5b58\u7684\u5a92\u4f53");
        return;
    }

    NSMutableSet<NSString *> *set = [NSMutableSet set];
    UIWindow *win = view.window ?: DYFallbackKeyWindow();
    UIView *scope = win ?: view;

    // v1.5 PHASE A: current item only (active player + most-visible cell + VC currentAweme)
    // Avoid pulling preloaded next/prev feed cells into the URL set.
    if (scope) {
        DYFallbackCollectActivePlayersInView(scope, set);
        DYFallbackCollectFromScrollViews(scope, set);
    }
    DYFallbackCollectFromView(view, set);
    DYFallbackCollectFromResponder(view, set);

    UIViewController *top = DYTopViewController();
    if (top) {
        // Prefer current/playing keys only (do not walk generic model lists)
        for (NSString *k in @[@"currentAweme", @"playingAweme", @"currentModel",
                              @"playingModel", @"currentVideo", @"playingVideo",
                              @"currentItem", @"playingItem"]) {
            @try {
                if ([top respondsToSelector:NSSelectorFromString(k)]) {
                    DYFallbackCollect([top valueForKey:k], set, 0);
                }
            } @catch (__unused NSException *e) {}
        }
        DYFallbackCollectFromResponder(top, set);
        if (top.isViewLoaded) {
            DYFallbackCollectActivePlayersInView(top.view, set);
            DYFallbackCollectFromScrollViews(top.view, set);
        }
        for (UIViewController *c in top.childViewControllers) {
            for (NSString *k in @[@"currentAweme", @"playingAweme", @"currentModel",
                                  @"playingModel", @"currentVideo", @"playingVideo",
                                  @"currentItem", @"playingItem"]) {
                @try {
                    if ([c respondsToSelector:NSSelectorFromString(k)]) {
                        DYFallbackCollect([c valueForKey:k], set, 0);
                    }
                } @catch (__unused NSException *e) {}
            }
            DYFallbackCollectFromResponder(c, set);
            if (c.isViewLoaded) {
                DYFallbackCollectActivePlayersInView(c.view, set);
                DYFallbackCollectFromScrollViews(c.view, set);
            }
        }
    }

    // PHASE B only if current-scope found no video (e.g. photo post / odd page)
    if (!DYSetHasVideoURL(set)) {
        NSLog(@"[DouyinSave] phaseA empty video; broaden collect");
        if (scope) {
            DYFallbackCollectPlayersInView(scope, set);
            DYFallbackCollectFromScrollViews(scope, set);
        }
        if (top) {
            DYFallbackCollectClassNamedModels(top, set, 0);
            if (top.isViewLoaded) {
                DYFallbackCollectPlayersInView(top.view, set);
            }
            for (UIViewController *c in top.childViewControllers) {
                DYFallbackCollectClassNamedModels(c, set, 0);
                if (c.isViewLoaded) DYFallbackCollectPlayersInView(c.view, set);
            }
        }
        if (win) {
            CGPoint prefer = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds) - 40);
            UIImageView *best = DYFallbackPickBestImageView(win, prefer);
            if (best) {
                DYFallbackCollectFromView(best, set);
                DYFallbackCollectFromResponder(best, set);
            }
        }
    }

    NSLog(@"[DouyinSave] collected %lu urls (current-first)", (unsigned long)set.count);

    for (NSString *u in set) {
        NSLog(@"[DouyinSave]  candidate score=%ld video=%d %@",
              (long)DYFallbackURLScore(u), (int)DYFallbackIsVideoURL(u),
              u.length > 180 ? [[u substringToIndex:180] stringByAppendingString:@"..."] : u);
    }

    // VIDEO FIRST: if any non-m3u8 video URL exists, only consider videos
    NSMutableArray<NSString *> *videos = [NSMutableArray array];
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    for (NSString *u in set) {
        if (DYFallbackIsVideoURL(u)) {
            if (![u.lowercaseString containsString:@".m3u8"]) [videos addObject:u];
        } else if (DYFallbackIsImageURL(u)) {
            [images addObject:u];
        }
    }

    NSComparator cmp = ^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger sa = DYFallbackURLScore(a), sb = DYFallbackURLScore(b);
        if (sa > sb) return NSOrderedAscending;
        if (sa < sb) return NSOrderedDescending;
        return NSOrderedSame;
    };

    if (videos.count) {
        NSArray *sorted = [videos sortedArrayUsingComparator:cmp];
        // Expand no-watermark variants, re-score, cap tries
        NSMutableSet<NSString *> *expanded = [NSMutableSet set];
        for (NSString *u in sorted) {
            for (NSString *v in DYNoWatermarkURLVariants(u)) {
                if (v.length) [expanded addObject:v];
            }
            if (expanded.count > 60) break;
        }
        NSArray *rescored = [expanded.allObjects sortedArrayUsingComparator:cmp];
        NSMutableArray<NSString *> *tryList = [NSMutableArray array];
        // Pass 1: download/origin only (original / high quality)
        for (NSString *u in rescored) {
            if (tryList.count >= 10) break;
            NSString *l = u.lowercaseString;
            BOOL isDL = [l containsString:@"download"] || [l containsString:@"origin_download"] ||
                        [l containsString:@"origindownload"];
            if (!isDL) continue;
            BOOL dup = NO;
            for (NSString *e in tryList) { if ([e isEqualToString:u]) { dup = YES; break; } }
            if (!dup) [tryList addObject:u];
        }
        // Pass 2: high-res / high-br play URLs
        for (NSString *u in rescored) {
            if (tryList.count >= 14) break;
            BOOL dup = NO;
            for (NSString *e in tryList) { if ([e isEqualToString:u]) { dup = YES; break; } }
            if (!dup) [tryList addObject:u];
        }
        NSLog(@"[DouyinSave] VIDEO pick top=%@ score=%ld (try %lu, expanded %lu)",
              tryList.firstObject,
              (long)DYFallbackURLScore(tryList.firstObject),
              (unsigned long)tryList.count, (unsigned long)expanded.count);
        DYFallbackDownloadVideosTry(tryList, 0);
        return;
    }

        // No video URL: do NOT silently save cover as "success"
    // v1.3: scan local cache OFF main thread (was watchdog crash after save / on open)
    DYFallbackToast(@"\u672a\u627e\u5230\u76f4\u94fe\uff0c\u626b\u63cf\u672c\u5730\u7f13\u5b58\u2026");
    NSArray *imageCopy = [images copy];
    NSComparator cmpCopy = cmp;
    UIView *viewRef = view;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *bestFile = nil;
        @autoreleasepool {
            NSMutableArray<NSString *> *roots = [NSMutableArray array];
            if (NSTemporaryDirectory().length) [roots addObject:NSTemporaryDirectory()];
            NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            if (caches.length) [roots addObject:caches];
            // skip Library/Documents deep scan — too heavy, caused freezes
            unsigned long long bestScore = 0;
            NSFileManager *fm = [NSFileManager defaultManager];
            NSMutableArray<NSDictionary *> *cands = [NSMutableArray array];
            for (NSString *root in roots) {
                if (root.length == 0) continue;
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:root];
                NSInteger seen = 0;
                for (NSString *rel in en) {
                    if (++seen > 900) break;
                    NSString *low = rel.lowercaseString;
                    if (!([low hasSuffix:@".mp4"] || [low hasSuffix:@".mov"] || [low hasSuffix:@".m4v"])) continue;
                    if ([low containsString:@"snap"] || [low containsString:@"thumb"] ||
                        [low containsString:@"cover"] || [low containsString:@"gif"]) continue;
                    NSString *full = [root stringByAppendingPathComponent:rel];
                    NSDictionary *attr = [fm attributesOfItemAtPath:full error:nil];
                    unsigned long long sz = attr.fileSize;
                    if (sz < 400 * 1024) continue;
                    NSDate *mod = attr.fileModificationDate;
                    NSTimeInterval age = mod ? [[NSDate date] timeIntervalSinceDate:mod] : 1e12;
                    if (age > 45 * 60) continue; // only recent 45min
                    unsigned long long sc = sz + (unsigned long long)MAX(0.0, (45 * 60 - age)) * 2000ULL;
                    [cands addObject:@{@"p": full, @"s": @(sc)}];
                }
            }
            [cands sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [b[@"s"] compare:a[@"s"]];
            }];
            NSInteger checked = 0;
            for (NSDictionary *c in cands) {
                if (++checked > 12) break;
                NSString *full = c[@"p"];
                if (DYFallbackFileLooksPlayableVideo(full)) {
                    bestFile = full;
                    break;
                }
            }
        }
        if (bestFile.length) {
            NSLog(@"[DouyinSave] local cache video %@", bestFile);
            dispatch_async(dispatch_get_main_queue(), ^{
                DYFallbackDownloadVideosTry(@[[NSURL fileURLWithPath:bestFile].absoluteString], 0);
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (imageCopy.count) {
                NSArray *sorted = [imageCopy sortedArrayUsingComparator:cmpCopy];
                NSString *pick = sorted.firstObject;
                NSLog(@"[DouyinSave] IMAGE-only pick %@", pick);
                DYFallbackToast(@"未找到视频地址，改为保存封面图…");
                DYFallbackDownloadAndSaveImage(pick);
                return;
            }
            if (viewRef.bounds.size.width > 48 && viewRef.bounds.size.height > 48) {
                if (@available(iOS 10.0, *)) {
                    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:viewRef.bounds.size];
                    UIImage *snap = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                        [viewRef drawViewHierarchyInRect:viewRef.bounds afterScreenUpdates:NO];
                    }];
                    if (snap) {
                        DYFallbackSaveImage(snap, ^(BOOL ok, NSError *e) {
                            DYFallbackToast(ok ? @"✅ 仅截图保存(非视频原文件)" :
                                             [NSString stringWithFormat:@"保存失败: %@",
                                              e.localizedDescription ?: @"?"]);
                        });
                        return;
                    }
                }
            }
            DYFallbackToast(@"未找到可保存的视频地址");
        });
    });
    return;
    } @catch (__unused NSException *e) {
        NSLog(@"[DouyinSave] forceSave exception: %@", e);
        DYFallbackToast(@"保存过程异常，请重试");
    }
}


@interface DYFallbackFloatUI : NSObject
+ (void)install;
@end

@implementation DYFallbackFloatUI

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __block __weak void (^weakTryAttach)(void) = nil;
        void (^tryAttach)(void) = ^{
            void (^strongTry)(void) = weakTryAttach;
            UIWindow *win = DYFallbackKeyWindow();
            if (!win) {
                if (!strongTry) return;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), strongTry);
                return;
            }
            [self attachToWindow:win];
        };
        weakTryAttach = tryAttach;
        // wait until home/window exists; do not run at ctor
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), tryAttach);
    });
}

+ (void)attachToWindow:(UIWindow *)win {
    if (!win) return;
    if (objc_getAssociatedObject(win, _cmd)) return;
    objc_setAssociatedObject(win, _cmd, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat w = win.bounds.size.width, h = win.bounds.size.height;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(w - 58, h * 0.55, 46, 46);
    btn.backgroundColor = [[UIColor colorWithRed:0.10 green:0.95 blue:0.88 alpha:1] colorWithAlphaComponent:0.90];
    btn.layer.cornerRadius = 23;
    btn.layer.shadowColor = UIColor.blackColor.CGColor;
    btn.layer.shadowOpacity = 0.28;
    btn.layer.shadowRadius = 3.5;
    btn.layer.shadowOffset = CGSizeMake(0, 2);
    [btn setTitle:@"\u2193" forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                           UIViewAutoresizingFlexibleTopMargin |
                           UIViewAutoresizingFlexibleBottomMargin;
    [btn addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [btn addGestureRecognizer:pan];
    [win addSubview:btn];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(twoFinger:)];
    lp.numberOfTouchesRequired = 2;
    lp.minimumPressDuration = 0.35;
    [win addGestureRecognizer:lp];

    NSLog(@"[DouyinSave] v1.4 float ready on %@", win);
    DYFallbackToast(@"\u89c6\u9891/\u56fe\u7247\u4fdd\u5b58\u5df2\u52a0\u8f7d(\u70b9\u2193\u6216\u53cc\u6307\u957f\u6309)");
}

+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

+ (void)tap:(UIButton *)sender {
    UIWindow *win = sender.window ?: DYFallbackKeyWindow();
    if (!win) return;
    // Prefer full window graph so feed video models are collected (not cover UIImageView only)
    DYFallbackForceSaveFromView(win);
}

+ (void)twoFinger:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:g.view];
    UIView *hit = [g.view hitTest:p withEvent:nil] ?: g.view;
    UIView *img = hit;
    while (img && ![img isKindOfClass:[UIImageView class]]) img = img.superview;
    if (!img && [g.view isKindOfClass:[UIWindow class]]) {
        img = DYFallbackPickBestImageView((UIWindow *)g.view, p);
    }
    DYFallbackForceSaveFromView(img ?: hit);
}

@end

#pragma mark - delayed re-patch

// v1.4: minimal AWE download gates only (no XHS leftovers)
static void DYInstallMinimalAwemeGates(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *known[] = {
            "AWEAwemeModel",
            "AWEVideoModel",
            "AWEAwemeStatusModel",
            "AWEDownloadPermissionItem",
            "AWEDownloadSettingUtil",
            "AWEDownloadEntranceHelper",
            "AWEAwemeDetailNaviBarDownloadElement",
            NULL
        };
        for (const char **p = known; *p; p++) {
            Class cls = objc_getClass(*p);
            if (!cls) continue;
            DYPatchBool(cls, "preventDownload", NO);
            DYPatchBool(cls, "hasPreventDownload", NO);
            DYPatchBool(cls, "isPreventDownload", NO);
            DYPatchBool(cls, "shouldPreventDownload", NO);
            DYPatchBool(cls, "isControlledByPreventDownload", NO);
            DYPatchBool(cls, "allowDownload", YES);
            DYPatchBool(cls, "canDownload", YES);
            DYPatchBool(cls, "shouldShowDownload", YES);
            DYPatchBool(cls, "isDownloadEnabled", YES);
            DYPatchBool(cls, "downloadEnabled", YES);
            DYPatchBool(cls, "disableWatermark", YES);
            DYPatchBool(cls, "disableWatermarkWhenSavingAlbum", YES);
        }
        NSLog(@"[DouyinSave] v1.6 minimal AWE gates installed");
    });
}

static void DYRepatchCore(void) {
    // v1.4: gates only
    DYInstallMinimalAwemeGates();
}

static void DYDeferredHeavyInstall(void) {
    // no-op: full scans removed
}

#pragma mark - ctor

__attribute__((constructor))
static void DYInit(void) {
    @autoreleasepool {
        if (!DYIsTarget()) return;
        // v1.4 SAFE BOOT: do NOT touch JSON / UserDefaults / toast / i18n / XHS save services.
        // Those global hooks are the main cause of immediate Aweme crash-on-launch.
        NSLog(@"[DouyinSave] v1.6 quality load pid=%d (float-save only)", getpid());

        // Float UI only — after app UI is up
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [DYFallbackFloatUI install];
            } @catch (__unused NSException *e) {
                NSLog(@"[DouyinSave] float install exception: %@", e);
            }
        });

        // Optional light gate unlock after feed likely loaded (background)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                @try {
                    DYInstallMinimalAwemeGates();
                } @catch (__unused NSException *e) {
                    NSLog(@"[DouyinSave] gate install exception: %@", e);
                }
            }
        });
    }
}
