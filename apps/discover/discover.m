//
// discover.dylib - Xiaohongshu unlock native image/video save (perf-first)
// Bundle: com.xingin.discover | executable: discover | analyzed: 9.38.1
//
// v8 (perf/stability fix):
//   - REMOVE NSBundle localizedStringForKey global hook (launch hang)
//   - NO class-list scans in constructor; known-class only at load
//   - ONE deferred background scan after UI is up
//   - toast/i18n: known hosts only at load; optional deferred scan
//   - NSURLSession hook disabled
//   - JSON rewrite size-capped; no force-mutable on every parse
//   - mediaSaveConfig / repatch no longer re-scan all classes at load
//
// v7:
//   - Match real capa toast + capa_allow_download_account_toast
//   - Stronger SaveProvider unlock
//
// v6/v5: mediaSaveConfig / privacy defaults / JSON rewrite
//
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <pthread.h>
#import <unistd.h>

static const BOOL kVerbose = NO;
#define LOG(fmt, ...) do { if (kVerbose) NSLog(@"[XHSMediaSave] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - target

static BOOL XHSIsTarget(void) {
    static int cached = -1;
    if (cached >= 0) return cached != 0;
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSString *exe = [[NSBundle mainBundle].executablePath lastPathComponent] ?: @"";
    cached = ([bid isEqualToString:@"com.xingin.discover"] ||
              [exe isEqualToString:@"discover"]) ? 1 : 0;
    return cached != 0;
}

#pragma mark - bool / void stubs

static BOOL XHS_retNO(id s, SEL c) { (void)s; (void)c; return NO; }
static BOOL XHS_retYES(id s, SEL c) { (void)s; (void)c; return YES; }
static id   XHS_retYesObj(id s, SEL c) { (void)s; (void)c; return @YES; }
static id   XHS_retNoObj(id s, SEL c) { (void)s; (void)c; return @NO; }
static void XHS_void0(id s, SEL c) { (void)s; (void)c; }
static void XHS_setBoolDrop(id s, SEL c, BOOL v) { (void)s; (void)c; (void)v; }

static void XHSPatchBool(Class cls, const char *selName, BOOL value) {
    if (!cls || !selName) return;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    if (!t) return;
    if (t[0] == 'B' || t[0] == 'c') {
        method_setImplementation(m, value ? (IMP)XHS_retYES : (IMP)XHS_retNO);
        LOG(@"%s -%s => %d", class_getName(cls), selName, (int)value);
    } else if (t[0] == '@') {
        method_setImplementation(m, value ? (IMP)XHS_retYesObj : (IMP)XHS_retNoObj);
        LOG(@"%s -%s => @%d", class_getName(cls), selName, (int)value);
    }
}

static void XHSPatchVoid(Class cls, const char *selName) {
    if (!cls || !selName) return;
    Method m = class_getInstanceMethod(cls, sel_registerName(selName));
    if (!m) return;
    if (method_getNumberOfArguments(m) == 2) {
        method_setImplementation(m, (IMP)XHS_void0);
        LOG(@"nop %s -%s", class_getName(cls), selName);
    }
}

static void XHSPatchSetterDrop(Class cls, const char *selName) {
    if (!cls || !selName) return;
    Method m = class_getInstanceMethod(cls, sel_registerName(selName));
    if (!m) return;
    method_setImplementation(m, (IMP)XHS_setBoolDrop);
}

static BOOL XHSNameLooksSaveProvider(const char *name) {
    if (!name) return NO;
    return strstr(name, "SaveProvider") ||
           strstr(name, "SaveCell") ||
           strstr(name, "ImageSave") ||
           strstr(name, "SaveImage") ||
           strstr(name, "NegativeFeedback") ||
           strstr(name, "MediaSave") ||
           strstr(name, "NotePaidDownload") ||
           strstr(name, "VideoDownloader");
}

static void XHSPatchKnownClass(Class cls);

static void XHSForceConfigObject(id cfg) {
    if (!cfg) return;
    XHSPatchKnownClass(object_getClass(cfg));
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

static void XHSPatchKnownClass(Class cls) {
    if (!cls) return;

    // disableSave -> allow
    XHSPatchBool(cls, "disableSave", NO);
    XHSPatchBool(cls, "isDisableSave", NO);
    XHSPatchBool(cls, "forbidCopy", NO);
    XHSPatchBool(cls, "disableCopy", NO);
    XHSPatchBool(cls, "disableCopyAction", NO);
    // author download switch
    XHSPatchBool(cls, "disableWatermark", YES);
    XHSPatchBool(cls, "disableWatermarkWhenSavingAlbum", YES);
    XHSPatchSetterDrop(cls, "setDisableSave:");
    XHSPatchSetterDrop(cls, "setForbidCopy:");
    XHSPatchSetterDrop(cls, "setDisableCopy:");

    // watermark-related flags if present
    XHSPatchBool(cls, "hitUserNoteDownloadSwitch", NO);
    XHSPatchBool(cls, "hitRacingUserNoteDownloadSwitch", NO);
    XHSPatchBool(cls, "userNoteDownloadSwitch", YES);
    XHSPatchBool(cls, "isFlowDownloadSwitchOn", YES);
    XHSPatchBool(cls, "notAllowDownloadMyVideos", NO);
    XHSPatchBool(cls, "notAllowDownloadMyVideosSwitchOn", NO);
    XHSPatchBool(cls, "allowDownload", YES);
    XHSPatchBool(cls, "shareImageSaveEnable", YES);
    XHSPatchBool(cls, "shareVideoSaveEnable", YES);
    XHSPatchBool(cls, "userVideoDownloadSwitch", YES);
    XHSPatchBool(cls, "videoDownloadSwitch", YES);
    XHSPatchBool(cls, "mobileDownloadSwitch", YES);
    XHSPatchBool(cls, "enableSave", YES);
    XHSPatchBool(cls, "saveEnable", YES);
    XHSPatchBool(cls, "hasSaveNotAllowDownloadMyVideosKey", NO);
    XHSPatchBool(cls, "isShowedAdvanceOptionNoteDownloadTips", YES);

    // enable only for save-related classes
    if (XHSNameLooksSaveProvider(class_getName(cls))) {
        XHSPatchBool(cls, "enable", YES);
        XHSPatchBool(cls, "isEnabled", YES);
        XHSPatchBool(cls, "isAvailable", YES);
        XHSPatchBool(cls, "canSave", YES);
        XHSPatchBool(cls, "canDownload", YES);
        // avoid paid-image branch only; do not crack paid download wall
        XHSPatchBool(cls, "isPaidImageNote", NO);
        XHSPatchBool(cls, "isPaidDownload", NO);
        XHSPatchBool(cls, "hasPaidDownload", NO);
        XHSPatchBool(cls, "showPaidDownload", NO);
    }

    XHSPatchVoid(cls, "checkShowCloseNoteDownloadSwitchToast");
    XHSPatchVoid(cls, "showCloseNoteDownloadSwitchToast");
    XHSPatchVoid(cls, "showDownloadPermissionToast");
    XHSPatchSetterDrop(cls, "setNotAllowDownloadMyVideos:");
    XHSPatchSetterDrop(cls, "setNotAllowDownloadMyVideosSwitchOn:");
    XHSPatchSetterDrop(cls, "setHitUserNoteDownloadSwitch:");
    XHSPatchSetterDrop(cls, "setHitRacingUserNoteDownloadSwitch:");
}

#pragma mark - once class hooks

static void XHSInstallClassHooksKnown(void) {
    const char *known[] = {
        "XYPHMediaSaveConfig",
        "XYVFVideoDownloaderManager",
        "XYNoteFeedbackFloatingConfig",
        "NoteFeedbackFloatingConfig",
        "_TtC18XYNegativeFeedback12SaveProvider",
        "SaveProvider",
        "_TtC18XYNegativeFeedback18SaveCellController",
        "SaveCellController",
        "_TtC18XYNegativeFeedback16SaveImageService",
        "SaveImageService",
        "_TtC12XYNoteModule16ImageSaveService",
        "ImageSaveService",
        "_TtC12XYNoteModule19ImageSaveServiceAPM",
        "_TtC18XYNegativeFeedback24NotePaidDownloadProvider",
        "NotePaidDownloadProvider",
        NULL
    };
    for (const char **p = known; *p; p++) {
        XHSPatchKnownClass(objc_getClass(*p));
    }
}

static void XHSScanClassHooks(void) {
    // deferred only - never call from constructor
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;

    unsigned patched = 0;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = list[i];
        if (class_getInstanceMethod(cls, sel_registerName("disableSave")) ||
            class_getInstanceMethod(cls, sel_registerName("hitUserNoteDownloadSwitch")) ||
            class_getInstanceMethod(cls, sel_registerName("isFlowDownloadSwitchOn")) ||
            class_getInstanceMethod(cls, sel_registerName("userNoteDownloadSwitch")) ||
            class_getInstanceMethod(cls, sel_registerName("checkShowCloseNoteDownloadSwitchToast")) ||
            class_getInstanceMethod(cls, sel_registerName("notAllowDownloadMyVideos")) ||
            class_getInstanceMethod(cls, sel_registerName("notAllowDownloadMyVideosSwitchOn")) ||
            class_getInstanceMethod(cls, sel_registerName("shareImageSaveEnable")) ||
            class_getInstanceMethod(cls, sel_registerName("shareVideoSaveEnable")) ||
            class_getInstanceMethod(cls, sel_registerName("isPaidImageNote"))) {
            XHSPatchKnownClass(cls);
            if (++patched > 80) break;
        }
    }
    free(list);
    LOG(@"class scan done, patched=%u / %u", patched, n);
}

static void XHSInstallClassHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        XHSInstallClassHooksKnown();
        LOG(@"class hooks known-only (v8)");
    });
}

#pragma mark - object tree rewrite (NSJSONSerialization path)

static BOOL XHSLooksTruthy(id v) {
    if (!v || v == [NSNull null]) return NO;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        return [s isEqualToString:@"1"] || [s isEqualToString:@"true"] || [s isEqualToString:@"yes"];
    }
    return NO;
}

static BOOL XHSLooksFalsey(id v) {
    if (!v || v == [NSNull null]) return YES;
    if ([v isKindOfClass:[NSNumber class]]) return ![(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        return [s isEqualToString:@"0"] || [s isEqualToString:@"false"] || [s isEqualToString:@"no"] || s.length == 0;
    }
    return NO;
}

static BOOL XHSPatchObjectTree(id obj, NSInteger depth) {
    if (!obj || depth > 8) return NO;
    BOOL changed = NO;

    if ([obj isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *md = (NSMutableDictionary *)obj;
        static NSSet<NSString *> *forceFalse;
        static NSSet<NSString *> *forceTrue;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            forceFalse = [NSSet setWithArray:@[
                @"disable_save", @"disableSave",
                @"forbid_copy", @"forbidCopy",
                @"hitUserNoteDownloadSwitch", @"hit_user_note_download_switch",
                @"hitRacingUserNoteDownloadSwitch", @"hit_racing_user_note_download_switch",
                @"notAllowDownloadMyVideos", @"not_allow_download_my_videos",
                @"notAllowDownloadMyVideosSwitchOn",
                @"privacyCloseNoteDownload", @"privacy_close_note_download",
            ]];
            forceTrue = [NSSet setWithArray:@[
                @"userNoteDownloadSwitch", @"user_note_download_switch",
                @"userVideoDownloadSwitch", @"user_video_download_switch",
                @"isFlowDownloadSwitchOn", @"is_flow_download_switch_on",
                @"shareImageSaveEnable", @"share_image_save_enable",
                @"shareVideoSaveEnable", @"share_video_save_enable",
                @"allowDownload", @"allow_download",
                @"mobile_download_switch", @"mobileDownloadSwitch",
                @"videoDownloadSwitch", @"video_download_switch",
                @"disable_watermark", @"disableWatermark",
                @"disableWatermarkWhenSavingAlbum",
                @"enableSave", @"saveEnable",
                @"enable_save_photo_default",
            ]];
        });

        NSArray *keys = md.allKeys;
        for (id key in keys) {
            if (![key isKindOfClass:[NSString class]]) continue;
            NSString *k = (NSString *)key;
            id val = md[k];

            if ([forceFalse containsObject:k] && XHSLooksTruthy(val)) {
                md[k] = @NO;
                changed = YES;
            } else if ([forceTrue containsObject:k] && XHSLooksFalsey(val)) {
                md[k] = @YES;
                changed = YES;
            } else if ([val isKindOfClass:[NSDictionary class]] ||
                       [val isKindOfClass:[NSArray class]]) {
                if ([val isKindOfClass:[NSDictionary class]] &&
                    ![val isKindOfClass:[NSMutableDictionary class]]) {
                    NSMutableDictionary *child = [val mutableCopy];
                    if (XHSPatchObjectTree(child, depth + 1)) {
                        md[k] = child;
                        changed = YES;
                    }
                } else if ([val isKindOfClass:[NSArray class]] &&
                           ![val isKindOfClass:[NSMutableArray class]]) {
                    NSMutableArray *child = [val mutableCopy];
                    if (XHSPatchObjectTree(child, depth + 1)) {
                        md[k] = child;
                        changed = YES;
                    }
                } else {
                    if (XHSPatchObjectTree(val, depth + 1)) changed = YES;
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
                if (XHSPatchObjectTree(child, depth + 1)) {
                    ma[i] = child;
                    changed = YES;
                }
            } else if ([val isKindOfClass:[NSArray class]] &&
                       ![val isKindOfClass:[NSMutableArray class]]) {
                NSMutableArray *child = [val mutableCopy];
                if (XHSPatchObjectTree(child, depth + 1)) {
                    ma[i] = child;
                    changed = YES;
                }
            } else if ([val isKindOfClass:[NSMutableDictionary class]] ||
                       [val isKindOfClass:[NSMutableArray class]]) {
                if (XHSPatchObjectTree(val, depth + 1)) changed = YES;
            }
        }
        return changed;
    }

    return NO;
}

static id XHSMaybePatchJSONObject(id obj) {
    if (!obj) return obj;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *md = [obj mutableCopy];
        if (XHSPatchObjectTree(md, 0)) {
            LOG(@"json object dict patched");
            return md;
        }
        return obj;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *ma = [obj mutableCopy];
        if (XHSPatchObjectTree(ma, 0)) {
            LOG(@"json object array patched");
            return ma;
        }
        return obj;
    }
    return obj;
}

#pragma mark - raw JSON bytes patch (fallback)

static BOOL XHSDataLooksRelated(NSData *data) {
    if (data.length < 32 || data.length > 8 * 1024 * 1024) return NO;
    static NSArray<NSData *> *needles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        needles = @[
            [@"disable_save" dataUsingEncoding:NSUTF8StringEncoding],
            [@"disableSave" dataUsingEncoding:NSUTF8StringEncoding],
            [@"media_save_config" dataUsingEncoding:NSUTF8StringEncoding],
            [@"mediaSaveConfig" dataUsingEncoding:NSUTF8StringEncoding],
            [@"user_video_download_switch" dataUsingEncoding:NSUTF8StringEncoding],
            [@"userNoteDownloadSwitch" dataUsingEncoding:NSUTF8StringEncoding],
            [@"hitUserNoteDownloadSwitch" dataUsingEncoding:NSUTF8StringEncoding],
            [@"notAllowDownloadMyVideos" dataUsingEncoding:NSUTF8StringEncoding],
            [@"shareImageSaveEnable" dataUsingEncoding:NSUTF8StringEncoding],
            [@"share_image_save_enable" dataUsingEncoding:NSUTF8StringEncoding],
            [@"allow_download" dataUsingEncoding:NSUTF8StringEncoding],
            [@"capa_allow_download" dataUsingEncoding:NSUTF8StringEncoding],
            [@"privacyCloseNoteDownload" dataUsingEncoding:NSUTF8StringEncoding],
        ];
    });
    NSRange full = NSMakeRange(0, data.length);
    for (NSData *n in needles) {
        if ([data rangeOfData:n options:0 range:full].location != NSNotFound) return YES;
    }
    return NO;
}

static NSData *XHSPatchNoteJSONBytes(NSData *data) {
    if (!XHSDataLooksRelated(data)) return data;

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
    if (!data.length || data.length > 512 * 1024 || !XHSDataLooksRelated(data)) {
        return orig_JSONObjectWithData ? orig_JSONObjectWithData(self, _cmd, data, opt, err) : nil;
    }
    NSData *use = data;
    @try { use = XHSPatchNoteJSONBytes(data); }
    @catch (__unused NSException *e) { use = data; }
    NSJSONReadingOptions o2 = opt | NSJSONReadingMutableContainers;
    id obj = orig_JSONObjectWithData ? orig_JSONObjectWithData(self, _cmd, use, o2, err) : nil;
    if (!obj) return obj;
    @try {
        id patched = XHSMaybePatchJSONObject(obj);
        return patched ?: obj;
    } @catch (__unused NSException *e) {
        return obj;
    }
}

static void XHSInstallJSONHook(void) {
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

typedef void (^XHSDataCompletion)(NSData *, NSURLResponse *, NSError *);
static id (*orig_dataTask)(id, SEL, NSURLRequest *, XHSDataCompletion);

static id hook_dataTask(id self, SEL _cmd, NSURLRequest *req, XHSDataCompletion completion) {
    if (!completion) return orig_dataTask(self, _cmd, req, completion);
    XHSDataCompletion wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSData *patched = data;
        if (!err && data.length) {
            @try { patched = XHSPatchNoteJSONBytes(data); }
            @catch (__unused NSException *e) { patched = data; }
        }
        completion(patched, resp, err);
    };
    return orig_dataTask(self, _cmd, req, wrapped);
}

static void XHSInstallSessionHook(void) {
    // v8: disabled - wrapping every dataTask stalls feed/home networking.
    (void)hook_dataTask;
    (void)orig_dataTask;
    LOG(@"NSURLSession hook skipped (v8)");
}

#pragma mark - mediaSaveConfig getter / setter

static const void *kXHSOrigGetKey = &kXHSOrigGetKey;
static const void *kXHSOrigSetKey = &kXHSOrigSetKey;

static IMP XHSLoadOrigIMP(Class cls, const void *key) {
    if (!cls) return NULL;
    NSValue *v = objc_getAssociatedObject((id)cls, key);
    return v ? (IMP)v.pointerValue : NULL;
}

static void XHSStoreOrigIMP(Class cls, const void *key, IMP imp) {
    if (!cls || !imp) return;
    objc_setAssociatedObject((id)cls, key, [NSValue valueWithPointer:imp], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id hook_msc_get(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    IMP orig = XHSLoadOrigIMP(cls, kXHSOrigGetKey);
    // walk superclass chain if subclass has no stored IMP
    while (!orig && cls) {
        cls = class_getSuperclass(cls);
        orig = XHSLoadOrigIMP(cls, kXHSOrigGetKey);
    }
    id cfg = orig ? ((id (*)(id, SEL))orig)(self, _cmd) : nil;
    XHSForceConfigObject(cfg);
    return cfg;
}

static void hook_msc_set(id self, SEL _cmd, id cfg) {
    XHSForceConfigObject(cfg);
    Class cls = object_getClass(self);
    IMP orig = XHSLoadOrigIMP(cls, kXHSOrigSetKey);
    while (!orig && cls) {
        cls = class_getSuperclass(cls);
        orig = XHSLoadOrigIMP(cls, kXHSOrigSetKey);
    }
    if (orig) {
        ((void (*)(id, SEL, id))orig)(self, _cmd, cfg);
    }
}

static BOOL XHSIsBlockedSaveKey(NSString *key) {
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

static BOOL XHSIsForcedAllowKey(NSString *key) {
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
    if (XHSIsBlockedSaveKey(key)) {
        value = @NO;
    } else if (XHSIsForcedAllowKey(key)) {
        value = @YES;
    }
    if (orig_cfg_setValue) orig_cfg_setValue(self, _cmd, value, key);
}

static id (*orig_cfg_valueForKey)(id, SEL, NSString *);
static id hook_cfg_valueForKey(id self, SEL _cmd, NSString *key) {
    if (XHSIsBlockedSaveKey(key)) return @NO;
    if (XHSIsForcedAllowKey(key)) return @YES;
    return orig_cfg_valueForKey ? orig_cfg_valueForKey(self, _cmd, key) : nil;
}

static BOOL XHSNameLooksNoteMedia(const char *name) {
    if (!name) return NO;
    return strstr(name, "Note") || strstr(name, "Video") || strstr(name, "Feed") ||
           strstr(name, "XYPH") || strstr(name, "XYVF") || strstr(name, "Share") ||
           strstr(name, "Media") || strstr(name, "ImageSave") || strstr(name, "NegativeFeedback");
}

static void XHSInstallMediaSaveConfigLight(void) {
    Class cfgCls = objc_getClass("XYPHMediaSaveConfig");
    if (!cfgCls) return;
    XHSPatchKnownClass(cfgCls);
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

static void XHSScanMediaSaveConfigHooks(void) {
    // deferred only
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    unsigned g = 0, s = 0;
    for (unsigned int i = 0; i < n && (g < 24 || s < 24); i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!XHSNameLooksNoteMedia(name)) continue;

        Method gm = class_getInstanceMethod(cls, sel_registerName("mediaSaveConfig"));
        if (gm && g < 24) {
            const char *enc = method_getTypeEncoding(gm);
            IMP prev = method_getImplementation(gm);
            if (enc && enc[0] == '@' && prev && prev != (IMP)hook_msc_get) {
                Method superM = class_getInstanceMethod(class_getSuperclass(cls), sel_registerName("mediaSaveConfig"));
                if (!superM || method_getImplementation(gm) != method_getImplementation(superM) || class_getSuperclass(cls) == Nil) {
                    XHSStoreOrigIMP(cls, kXHSOrigGetKey, prev);
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
                    XHSStoreOrigIMP(cls, kXHSOrigSetKey, prev);
                    method_setImplementation(sm, (IMP)hook_msc_set);
                    s++;
                }
            }
        }
    }
    free(list);
    LOG(@"mediaSaveConfig scan get=%u set=%u", g, s);
}

static void XHSInstallMediaSaveConfigHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        XHSInstallMediaSaveConfigLight();
        LOG(@"mediaSaveConfig light install (v8)");
    });
}


#pragma mark - NSUserDefaults privacy keys

static BOOL XHSIsPrivacyDownloadKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    NSString *k = key.lowercaseString;
    if ([k containsString:@"privacyclosenotedownload"] ||
        [k containsString:@"hassavenotallowdownloadmyvideos"] ||
        [k containsString:@"ios_profile_privacy_user_note_download"] ||
        [k containsString:@"usernotedownload"] ||
        [k containsString:@"user_note_download"] ||
        [k containsString:@"user_video_download_switch"] ||
        [k containsString:@"uservideodownload"] ||
        [k containsString:@"notallowdownloadmyvideos"] ||
        [k containsString:@"hitusernotedownload"] ||
        [k containsString:@"capa_allow_download"]) {
        return YES;
    }
    return NO;
}

static BOOL XHSPrivacyKeyShouldAllow(NSString *key) {
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
    if (XHSIsPrivacyDownloadKey(key)) {
        BOOL allow = XHSPrivacyKeyShouldAllow(key);
        LOG(@"NSUserDefaults boolForKey:%@ => %d", key, (int)allow);
        return allow;
    }
    return orig_ud_boolForKey ? orig_ud_boolForKey(self, _cmd, key) : NO;
}

static id (*orig_ud_objectForKey)(id, SEL, NSString *);
static id hook_ud_objectForKey(id self, SEL _cmd, NSString *key) {
    if (XHSIsPrivacyDownloadKey(key)) {
        BOOL allow = XHSPrivacyKeyShouldAllow(key);
        LOG(@"NSUserDefaults objectForKey:%@ => %d", key, (int)allow);
        return allow ? @YES : @NO;
    }
    return orig_ud_objectForKey ? orig_ud_objectForKey(self, _cmd, key) : nil;
}

static void XHSInstallUserDefaultsHooks(void) {
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

static BOOL XHSStringLooksDownloadToast(NSString *s) {
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

static BOOL XHSIsBlockedDownloadToastText(id text) {
    if (!text || text == (id)[NSNull null]) return NO;
    if ([text isKindOfClass:[NSString class]]) {
        return XHSStringLooksDownloadToast((NSString *)text);
    }
    if ([text isKindOfClass:[NSNumber class]] ||
        [text isKindOfClass:[NSData class]] ||
        [text isKindOfClass:[NSDate class]]) {
        return NO;
    }
    if ([text isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)text;
        for (id key in d) {
            if (XHSIsBlockedDownloadToastText(key) || XHSIsBlockedDownloadToastText(d[key])) {
                return YES;
            }
        }
        for (NSString *k in @[@"key", @"toastKey", @"i18nKey", @"messageKey", @"msgKey",
                              @"message", @"msg", @"text", @"title", @"content", @"toast",
                              @"toastText", @"toastTitle", @"desc", @"subtitle"]) {
            id v = d[k];
            if (v && XHSIsBlockedDownloadToastText(v)) return YES;
        }
        return NO;
    }
    if ([text isKindOfClass:[NSArray class]]) {
        for (id x in (NSArray *)text) {
            if (XHSIsBlockedDownloadToastText(x)) return YES;
        }
        return NO;
    }

    @try {
        for (NSString *k in @[@"key", @"toastKey", @"i18nKey", @"messageKey",
                              @"message", @"msg", @"text", @"title", @"content", @"toast"]) {
            SEL sel = sel_registerName(k.UTF8String);
            if (![text respondsToSelector:sel]) continue;
            id v = [text valueForKey:k];
            if (XHSIsBlockedDownloadToastText(v)) return YES;
        }
    } @catch (__unused NSException *e) {}

    if ([text respondsToSelector:@selector(description)]) {
        NSString *desc = [text description];
        if (desc.length > 0 && desc.length < 512 && XHSStringLooksDownloadToast(desc)) {
            return YES;
        }
    }
    return NO;
}

static BOOL XHSToastArgsBlocked(id a, id b, id c) {
    return XHSIsBlockedDownloadToastText(a) ||
           XHSIsBlockedDownloadToastText(b) ||
           XHSIsBlockedDownloadToastText(c);
}

static NSMutableDictionary *XHSToastOrigMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static NSString *XHSToastMapKey(Class cls, SEL sel) {
    if (!cls || !sel) return nil;
    return [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
}

static void XHSToastStoreOrig(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    NSString *k = XHSToastMapKey(cls, sel);
    if (!k) return;
    @synchronized (XHSToastOrigMap()) {
        if (!XHSToastOrigMap()[k]) {
            XHSToastOrigMap()[k] = [NSValue valueWithPointer:imp];
        }
    }
}

static IMP XHSToastLoadOrig(id self, SEL sel) {
    if (!self || !sel) return NULL;
    Class cls = object_getClass(self);
    while (cls) {
        NSString *k = XHSToastMapKey(cls, sel);
        NSValue *v = nil;
        @synchronized (XHSToastOrigMap()) {
            v = XHSToastOrigMap()[k];
        }
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void hook_toast_msg1(id self, SEL _cmd, id msg) {
    if (XHSIsBlockedDownloadToastText(msg)) {
        LOG(@"drop toast1: %@", msg);
        return;
    }
    IMP orig = XHSToastLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id))orig)(self, _cmd, msg);
}

static void hook_toast_msg2(id self, SEL _cmd, id a, id b) {
    if (XHSToastArgsBlocked(a, b, nil)) {
        LOG(@"drop toast2");
        return;
    }
    IMP orig = XHSToastLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, a, b);
}

static void hook_toast_msg3(id self, SEL _cmd, id a, id b, id c) {
    if (XHSToastArgsBlocked(a, b, c)) {
        LOG(@"drop toast3");
        return;
    }
    IMP orig = XHSToastLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id, id))orig)(self, _cmd, a, b, c);
}

static void hook_toast_inview(id self, SEL _cmd, id view, id msg) {
    if (XHSIsBlockedDownloadToastText(msg)) {
        LOG(@"drop toastInView: %@", msg);
        return;
    }
    IMP orig = XHSToastLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, view, msg);
}

static BOOL XHSNameLooksToastHost(const char *name) {
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

static void XHSTryHookToastMethod(Class cls, const char *selName, IMP hook, unsigned *count, unsigned maxCount) {
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
    XHSToastStoreOrig(target, sel, cur);
    method_setImplementation(own, hook);
    (*count)++;
    LOG(@"toast hook %s %s", class_getName(cls), selName);
}

static void XHSInstallToastFiltersKnown(void) {
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
        "XHSAToastManager",
        "XHSAToastView",
        "__Toast__",
        "XYCapaToastEventHandler",
        "_TtC11XYCameraKit19XYToastEventHandler",
        NULL
    };

    unsigned c1 = 0, c2 = 0, c3 = 0, cv = 0;
    for (const char **p = known; *p; p++) {
        Class cls = objc_getClass(*p);
        if (!cls) continue;
        XHSTryHookToastMethod(cls, "showToastWithMessage:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showToast:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showToastOnMainThread:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showToastOnMainThreadWith:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showToastWithTitle:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showTextToastOnMiddle:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showErrorToastWithMessage:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showFailToastWithTip:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showTipsWithKey:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showWithToast:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showToastWithData:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "toastMsgInMainThreadWith:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "displayToastIfContentAvailable:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "horizon_asyn_showToastNew:", (IMP)hook_toast_msg1, &c1, 20);
        XHSTryHookToastMethod(cls, "showToast:msg:", (IMP)hook_toast_msg2, &c2, 20);
        XHSTryHookToastMethod(cls, "showToastWithMessage:to:", (IMP)hook_toast_msg2, &c2, 20);
        XHSTryHookToastMethod(cls, "showToastWithMessage:withKey:", (IMP)hook_toast_msg2, &c2, 20);
        XHSTryHookToastMethod(cls, "showErrorToastWithI18nKey:errorCode:", (IMP)hook_toast_msg2, &c2, 20);
        XHSTryHookToastMethod(cls, "showToast:supportAccessibility:", (IMP)hook_toast_msg2, &c2, 20);
        XHSTryHookToastMethod(cls, "showLivePhotoToastIfNeededWithToast:key:", (IMP)hook_toast_msg2, &c2, 20);
        XHSTryHookToastMethod(cls, "showToastInView:message:", (IMP)hook_toast_inview, &cv, 16);
        XHSTryHookToastMethod(cls, "showToastWithEvent:params:callback:", (IMP)hook_toast_msg3, &c3, 16);
        XHSTryHookToastMethod(cls, "_executeShowToast:context:completion:", (IMP)hook_toast_msg3, &c3, 16);
        XHSTryHookToastMethod(cls, "showToastWithToast:adjustKeyboard:offset:", (IMP)hook_toast_msg3, &c3, 16);
        XHSTryHookToastMethod(cls, "toast:callback:", (IMP)hook_toast_msg2, &c2, 16);
    }
    LOG(@"toast known c1=%u c2=%u c3=%u cv=%u", c1, c2, c3, cv);
}

static void XHSScanToastFilters(void) {
    // deferred only - keep bounds tight
    unsigned c1 = 0, c2 = 0, c3 = 0, cv = 0;
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n && (c1 < 20 || c2 < 16 || c3 < 10 || cv < 10); i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!XHSNameLooksToastHost(name)) continue;
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
            XHSTryHookToastMethod(cls, "showToastWithMessage:", (IMP)hook_toast_msg1, &c1, 20);
            XHSTryHookToastMethod(cls, "showToast:", (IMP)hook_toast_msg1, &c1, 20);
            XHSTryHookToastMethod(cls, "showToastWithData:", (IMP)hook_toast_msg1, &c1, 20);
            XHSTryHookToastMethod(cls, "showTipsWithKey:", (IMP)hook_toast_msg1, &c1, 20);
            XHSTryHookToastMethod(cls, "showFailToastWithTip:", (IMP)hook_toast_msg1, &c1, 20);
            XHSTryHookToastMethod(cls, "showErrorToastWithMessage:", (IMP)hook_toast_msg1, &c1, 20);
            XHSTryHookToastMethod(cls, "displayToastIfContentAvailable:", (IMP)hook_toast_msg1, &c1, 20);
            XHSTryHookToastMethod(cls, "horizon_asyn_showToastNew:", (IMP)hook_toast_msg1, &c1, 20);
            XHSTryHookToastMethod(cls, "showToastWithMessage:withKey:", (IMP)hook_toast_msg2, &c2, 16);
            XHSTryHookToastMethod(cls, "showToastWithMessage:to:", (IMP)hook_toast_msg2, &c2, 16);
            XHSTryHookToastMethod(cls, "showErrorToastWithI18nKey:errorCode:", (IMP)hook_toast_msg2, &c2, 16);
            XHSTryHookToastMethod(cls, "showToast:supportAccessibility:", (IMP)hook_toast_msg2, &c2, 16);
            XHSTryHookToastMethod(cls, "showToastWithEvent:params:callback:", (IMP)hook_toast_msg3, &c3, 10);
            XHSTryHookToastMethod(cls, "_executeShowToast:context:completion:", (IMP)hook_toast_msg3, &c3, 10);
            XHSTryHookToastMethod(cls, "showToastWithToast:adjustKeyboard:offset:", (IMP)hook_toast_msg3, &c3, 10);
            XHSTryHookToastMethod(cls, "showToastInView:message:", (IMP)hook_toast_inview, &cv, 10);
        }
    }
    free(list);
    LOG(@"toast scan c1=%u c2=%u c3=%u cv=%u", c1, c2, c3, cv);
}

static void XHSInstallToastFilters(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        XHSInstallToastFiltersKnown();
        LOG(@"toast filters known-only (v8)");
    });
}

static BOOL XHSIsBlockedI18nKey(NSString *key) {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    NSString *k = key.lowercaseString;
    return [k containsString:@"capa_allow_download_account_toast"] ||
           [k isEqualToString:@"capa_allow_download_account"] ||
           [k containsString:@"privacyclosenotedownload"] ||
           [k containsString:@"close_note_download"] ||
           [k containsString:@"notallowdownloadmyvideos"];
}

static NSMutableDictionary *XHSI18nOrigMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static void XHSI18nStoreOrig(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
    @synchronized (XHSI18nOrigMap()) {
        if (!XHSI18nOrigMap()[k]) {
            XHSI18nOrigMap()[k] = [NSValue valueWithPointer:imp];
        }
    }
}

static IMP XHSI18nLoadOrig(id self, SEL sel) {
    if (!self || !sel) return NULL;
    Class cls = object_getClass(self);
    while (cls) {
        NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
        NSValue *v = nil;
        @synchronized (XHSI18nOrigMap()) {
            v = XHSI18nOrigMap()[k];
        }
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static id hook_i18n_key1(id self, SEL _cmd, id key) {
    if (XHSIsBlockedI18nKey(key) || XHSIsBlockedDownloadToastText(key)) {
        LOG(@"i18n drop key1: %@", key);
        return @"";
    }
    IMP orig = XHSI18nLoadOrig(self, _cmd);
    return orig ? ((id (*)(id, SEL, id))orig)(self, _cmd, key) : nil;
}

static id hook_i18n_key2(id self, SEL _cmd, id key, id fallback) {
    if (XHSIsBlockedI18nKey(key) || XHSIsBlockedDownloadToastText(key)) {
        LOG(@"i18n drop key2: %@", key);
        return @"";
    }
    // also block if fallback itself is the download toast body
    if (XHSIsBlockedDownloadToastText(fallback)) {
        LOG(@"i18n drop fallback toast body");
        return @"";
    }
    IMP orig = XHSI18nLoadOrig(self, _cmd);
    return orig ? ((id (*)(id, SEL, id, id))orig)(self, _cmd, key, fallback) : nil;
}

static id hook_i18n_module_key(id self, SEL _cmd, id module, id key) {
    if (XHSIsBlockedI18nKey(key) || XHSIsBlockedDownloadToastText(key) ||
        XHSIsBlockedI18nKey(module) || XHSIsBlockedDownloadToastText(module)) {
        LOG(@"i18n drop module+key");
        return @"";
    }
    IMP orig = XHSI18nLoadOrig(self, _cmd);
    return orig ? ((id (*)(id, SEL, id, id))orig)(self, _cmd, module, key) : nil;
}

static id hook_i18n_cfg_key(id self, SEL _cmd, id cfg, id key, id def) {
    if (XHSIsBlockedI18nKey(key) || XHSIsBlockedDownloadToastText(key)) {
        LOG(@"i18n drop cfg key: %@", key);
        return @"";
    }
    if (XHSIsBlockedDownloadToastText(def)) return @"";
    IMP orig = XHSI18nLoadOrig(self, _cmd);
    return orig ? ((id (*)(id, SEL, id, id, id))orig)(self, _cmd, cfg, key, def) : nil;
}

static void XHSTryHookI18nMethod(Class cls, const char *selName, IMP hook, unsigned *count, unsigned maxCount) {
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
    XHSI18nStoreOrig(target, sel, cur);
    method_setImplementation(own, hook);
    (*count)++;
    LOG(@"i18n hook %s %s", class_getName(cls), selName);
}

static BOOL XHSNameLooksI18nHost(const char *name) {
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

static void XHSInstallI18nFiltersKnown(void) {
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
        XHSTryHookI18nMethod(cls, "getStringWithKey:", (IMP)hook_i18n_key1, &c1, 16);
        XHSTryHookI18nMethod(cls, "getStringWithKey:defaultValue:", (IMP)hook_i18n_key2, &c2, 16);
        XHSTryHookI18nMethod(cls, "localizedStringWithKey:", (IMP)hook_i18n_key1, &c1, 16);
        XHSTryHookI18nMethod(cls, "localizedStringWithKey:fallbackValue:", (IMP)hook_i18n_key2, &c2, 16);
        XHSTryHookI18nMethod(cls, "localizedStringWithKey:comment:", (IMP)hook_i18n_key2, &c2, 16);
        XHSTryHookI18nMethod(cls, "localizedStringWithModuleStr:key:", (IMP)hook_i18n_module_key, &c2, 16);
        XHSTryHookI18nMethod(cls, "localizedStringFromConfig:key:defaultString:", (IMP)hook_i18n_cfg_key, &c3, 12);
    }
    LOG(@"i18n known c1=%u c2=%u c3=%u", c1, c2, c3);
}

static void XHSScanI18nFilters(void) {
    unsigned c1 = 0, c2 = 0, c3 = 0;
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n && (c1 < 16 || c2 < 16 || c3 < 8); i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!XHSNameLooksI18nHost(name)) continue;
        if (class_getInstanceMethod(cls, sel_registerName("getStringWithKey:")) ||
            class_getInstanceMethod(cls, sel_registerName("localizedStringWithKey:")) ||
            class_getInstanceMethod(cls, sel_registerName("localizedStringWithKey:fallbackValue:")) ||
            class_getClassMethod(cls, sel_registerName("getStringWithKey:")) ||
            class_getClassMethod(cls, sel_registerName("localizedStringWithKey:"))) {
            XHSTryHookI18nMethod(cls, "getStringWithKey:", (IMP)hook_i18n_key1, &c1, 16);
            XHSTryHookI18nMethod(cls, "getStringWithKey:defaultValue:", (IMP)hook_i18n_key2, &c2, 16);
            XHSTryHookI18nMethod(cls, "localizedStringWithKey:", (IMP)hook_i18n_key1, &c1, 16);
            XHSTryHookI18nMethod(cls, "localizedStringWithKey:fallbackValue:", (IMP)hook_i18n_key2, &c2, 16);
            XHSTryHookI18nMethod(cls, "localizedStringWithKey:comment:", (IMP)hook_i18n_key2, &c2, 16);
            XHSTryHookI18nMethod(cls, "localizedStringWithModuleStr:key:", (IMP)hook_i18n_module_key, &c2, 12);
            XHSTryHookI18nMethod(cls, "localizedStringFromConfig:key:defaultString:", (IMP)hook_i18n_cfg_key, &c3, 8);
        }
    }
    free(list);
    LOG(@"i18n scan c1=%u c2=%u c3=%u", c1, c2, c3);
}

static void XHSInstallI18nFilters(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        XHSInstallI18nFiltersKnown();
        LOG(@"i18n filters known-only (v8)");
    });
}


#pragma mark - NSBundle localizedString (capa toast key)

static NSString *(*orig_bundle_localized)(id, SEL, NSString *, NSString *, NSString *);
static NSString *hook_bundle_localized(id self, SEL _cmd, NSString *key, NSString *value, NSString *table) {
    if (XHSIsBlockedI18nKey(key) || XHSIsBlockedDownloadToastText(key) ||
        XHSIsBlockedDownloadToastText(value)) {
        LOG(@"bundle i18n drop: %@ / %@", key, table);
        return @"";
    }
    return orig_bundle_localized ? orig_bundle_localized(self, _cmd, key, value, table) : (value ?: @"");
}

static void XHSInstallBundleI18nHook(void) {
    // v8: NEVER hook NSBundle localizedStringForKey - ultra-hot path, launch hang.
    (void)hook_bundle_localized;
    (void)orig_bundle_localized;
    LOG(@"NSBundle localizedString skipped (v8)");
}

#pragma mark - ImageSaveService native save entry

static NSMutableDictionary *XHSSaveOrigMap(void) {
    static NSMutableDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = [NSMutableDictionary dictionary];
    });
    return map;
}

static void XHSSaveStoreOrig(Class cls, SEL sel, IMP imp) {
    if (!cls || !sel || !imp) return;
    NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
    @synchronized (XHSSaveOrigMap()) {
        if (!XHSSaveOrigMap()[k]) {
            XHSSaveOrigMap()[k] = [NSValue valueWithPointer:imp];
        }
    }
}

static IMP XHSSaveLoadOrig(id self, SEL sel) {
    Class cls = object_getClass(self);
    while (cls) {
        NSString *k = [NSString stringWithFormat:@"%s|%s", class_getName(cls), sel_getName(sel)];
        NSValue *v = nil;
        @synchronized (XHSSaveOrigMap()) {
            v = XHSSaveOrigMap()[k];
        }
        if (v) return (IMP)v.pointerValue;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void hook_saveImageList(id self, SEL _cmd, id from, BOOL disableWatermark, id completion) {
    (void)disableWatermark;
    LOG(@"force saveImageList disableWatermark=YES");
    IMP orig = XHSSaveLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, BOOL, id))orig)(self, _cmd, from, YES, completion);
}

static void hook_saveImageAt(id self, SEL _cmd, id at, id from, BOOL disableWatermark, id completion) {
    (void)disableWatermark;
    LOG(@"force saveImageAt disableWatermark=YES");
    IMP orig = XHSSaveLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id, BOOL, id))orig)(self, _cmd, at, from, YES, completion);
}

static void hook_saveImageNoTrack(id self, SEL _cmd, id at, id from, BOOL disableWatermark, id completion) {
    (void)disableWatermark;
    LOG(@"force saveImageNoTrack disableWatermark=YES");
    IMP orig = XHSSaveLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id, BOOL, id))orig)(self, _cmd, at, from, YES, completion);
}

static void hook_saveOriginalList(id self, SEL _cmd, id from, id completion) {
    LOG(@"saveOriginalImageList pass");
    IMP orig = XHSSaveLoadOrig(self, _cmd);
    if (orig) ((void (*)(id, SEL, id, id))orig)(self, _cmd, from, completion);
}

static void XHSTryHookSaveMethod(Class cls, const char *selName, IMP hook, unsigned *count) {
    if (!cls || !selName || !hook) return;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    Method superM = class_getInstanceMethod(class_getSuperclass(cls), sel);
    if (superM && method_getImplementation(m) == method_getImplementation(superM)) return;
    IMP cur = method_getImplementation(m);
    if (cur == hook) return;
    XHSSaveStoreOrig(cls, sel, cur);
    method_setImplementation(m, hook);
    if (count) (*count)++;
    LOG(@"save hook %s %s", class_getName(cls), selName);
}

static void XHSInstallSaveMethodHooksKnown(void) {
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
        XHSPatchKnownClass(cls);
        XHSTryHookSaveMethod(cls, "saveImageListFrom:disableWatermark:saveAllCompletion:", (IMP)hook_saveImageList, &c);
        XHSTryHookSaveMethod(cls, "saveImageAt:from:disableWatermark:completion:", (IMP)hook_saveImageAt, &c);
        XHSTryHookSaveMethod(cls, "saveImageWithoutManualTrackAt:from:disableWatermark:completion:", (IMP)hook_saveImageNoTrack, &c);
        XHSTryHookSaveMethod(cls, "saveOriginalImageListFrom:saveAllCompletion:", (IMP)hook_saveOriginalList, &c);
    }
    LOG(@"save method known hooks=%u", c);
}

static void XHSScanSaveMethodHooks(void) {
    unsigned c = 0;
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n && c < 16; i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!name) continue;
        if (!(strstr(name, "ImageSave") || strstr(name, "SaveImage") || strstr(name, "MediaSave"))) continue;
        XHSPatchKnownClass(cls);
        XHSTryHookSaveMethod(cls, "saveImageListFrom:disableWatermark:saveAllCompletion:", (IMP)hook_saveImageList, &c);
        XHSTryHookSaveMethod(cls, "saveImageAt:from:disableWatermark:completion:", (IMP)hook_saveImageAt, &c);
        XHSTryHookSaveMethod(cls, "saveImageWithoutManualTrackAt:from:disableWatermark:completion:", (IMP)hook_saveImageNoTrack, &c);
    }
    free(list);
    LOG(@"save method scan hooks=%u", c);
}

static void XHSInstallSaveMethodHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        XHSInstallSaveMethodHooksKnown();
        LOG(@"save method hooks known-only (v8)");
    });
}

static void XHSInstallAuthorityPatchesKnown(void) {
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
        XHSPatchKnownClass(cls);
        XHSPatchBool(cls, "hasDownloadMyNotesAuthorityData", YES);
        XHSPatchBool(cls, "hasSaveNotAllowDownloadMyVideosKey", NO);
    }
}

static void XHSScanAuthorityPatches(void) {
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
        XHSPatchKnownClass(cls);
        XHSPatchBool(cls, "hasDownloadMyNotesAuthorityData", YES);
        XHSPatchBool(cls, "hasSaveNotAllowDownloadMyVideosKey", NO);
        patched++;
    }
    free(list);
    LOG(@"authority scan patches=%u", patched);
}

static void XHSInstallAuthorityPatches(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        XHSInstallAuthorityPatchesKnown();
        LOG(@"authority patches known-only (v8)");
    });
}

#pragma mark - delayed re-patch

static void XHSRepatchCore(void) {
    // light only - never full class scan on main thread
    XHSInstallClassHooksKnown();
    XHSInstallMediaSaveConfigLight();
    XHSInstallSaveMethodHooksKnown();
    XHSInstallToastFiltersKnown();
    XHSInstallI18nFiltersKnown();
    XHSInstallAuthorityPatchesKnown();
}

static void XHSDeferredHeavyInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // off main: one bounded class-list pass after UI is up
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                XHSScanClassHooks();
                XHSScanMediaSaveConfigHooks();
                XHSScanSaveMethodHooks();
                XHSScanToastFilters();
                XHSScanI18nFilters();
                XHSScanAuthorityPatches();
                LOG(@"v8 deferred heavy install done");
            }
        });
    });
}

#pragma mark - ctor

__attribute__((constructor))
static void XHSInit(void) {
    @autoreleasepool {
        if (!XHSIsTarget()) return;
        LOG(@"v8 load pid=%d", getpid());

        // known-class only; no objc_copyClassList / no NSBundle / no session wrap
        XHSInstallClassHooks();
        XHSInstallJSONHook();
        // XHSInstallSessionHook(); // intentionally skipped in v8
        XHSInstallMediaSaveConfigHooks();
        XHSInstallUserDefaultsHooks();
        XHSInstallToastFilters();
        XHSInstallI18nFilters();
        // XHSInstallBundleI18nHook(); // intentionally skipped in v8
        XHSInstallSaveMethodHooks();
        XHSInstallAuthorityPatches();

        // Swift classes may register later - light repatch only
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSRepatchCore();
            LOG(@"v8 delayed light patch 1.2s");
        });
        // one heavy background scan after home is likely up
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSDeferredHeavyInstall();
        });
    }
}
