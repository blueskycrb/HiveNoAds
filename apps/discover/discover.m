//
// discover.dylib — 小红书：解锁别人帖子图片/视频保存（性能优先）
// Bundle: com.xingin.discover | 可执行名: discover | 对照: 9.38.1
//
// v4:
//   - 继续避免 NSObject 全局 KVC / 全量 toast 扫描（卡顿主因）
//   - NSJSONSerialization 解析结果改写下载开关（比只 hook NSURLSession block 更稳）
//   - 保留轻量 JSON 字节替换，兜住不走 NSJSONSerialization 的响应
//   - mediaSaveConfig getter/setter 按类保存原 IMP，定点强制 disableSave=NO
//   - 仅对 XYPHMediaSaveConfig 做 KVC 拦截
//   - 无悬浮按钮、不截图，走 App 原生「保存图片 / 保存视频」
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
              [exe isEqualToString:@"discover"] ||
              bid.length == 0) ? 1 : 0;
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
           strstr(name, "ImageSave") ||
           strstr(name, "SaveImage") ||
           strstr(name, "NegativeFeedback") ||
           strstr(name, "MediaSave");
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
    XHSPatchBool(cls, "allowDownload", YES);
    XHSPatchBool(cls, "shareImageSaveEnable", YES);
    XHSPatchBool(cls, "shareVideoSaveEnable", YES);
    XHSPatchBool(cls, "userVideoDownloadSwitch", YES);
    XHSPatchBool(cls, "videoDownloadSwitch", YES);
    XHSPatchBool(cls, "mobileDownloadSwitch", YES);
    XHSPatchBool(cls, "enableSave", YES);
    XHSPatchBool(cls, "saveEnable", YES);

    // enable only for save-related classes
    if (XHSNameLooksSaveProvider(class_getName(cls))) {
        XHSPatchBool(cls, "enable", YES);
    }

    XHSPatchVoid(cls, "checkShowCloseNoteDownloadSwitchToast");
    XHSPatchSetterDrop(cls, "setNotAllowDownloadMyVideos:");
    XHSPatchSetterDrop(cls, "setHitUserNoteDownloadSwitch:");
    XHSPatchSetterDrop(cls, "setHitRacingUserNoteDownloadSwitch:");
}

#pragma mark - once class hooks

static void XHSInstallClassHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *known[] = {
            "XYPHMediaSaveConfig",
            "XYVFVideoDownloaderManager",
            "XYNoteFeedbackFloatingConfig",
            "_TtC18XYNegativeFeedback12SaveProvider",
            "SaveProvider",
            "_TtC12XYNoteModule16ImageSaveService",
            "ImageSaveService",
            NULL
        };
        for (const char **p = known; *p; p++) {
            XHSPatchKnownClass(objc_getClass(*p));
        }

        // one-shot scan for key selectors
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
                class_getInstanceMethod(cls, sel_registerName("shareImageSaveEnable")) ||
                class_getInstanceMethod(cls, sel_registerName("shareVideoSaveEnable"))) {
                XHSPatchKnownClass(cls);
                if (++patched > 100) break;
            }
        }
        free(list);
        LOG(@"class hooks done, patched=%u / %u", patched, n);
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
    NSData *use = data;
    if (data.length) {
        @try { use = XHSPatchNoteJSONBytes(data); }
        @catch (__unused NSException *e) { use = data; }
    }
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
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("NSURLSession");
        if (!cls) return;
        SEL sel = @selector(dataTaskWithRequest:completionHandler:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) return;
        orig_dataTask = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_dataTask);
        LOG(@"NSURLSession dataTask hooked");
    });
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

// XYPHMediaSaveConfig KVC: force disableSave=NO
static void (*orig_cfg_setValue)(id, SEL, id, NSString *);
static void hook_cfg_setValue(id self, SEL _cmd, id value, NSString *key) {
    if ([key isKindOfClass:[NSString class]]) {
        NSString *k = key.lowercaseString;
        if ([k isEqualToString:@"disablesave"] ||
            [k isEqualToString:@"disable_save"] ||
            [k isEqualToString:@"forbidcopy"] ||
            [k isEqualToString:@"forbid_copy"]) {
            value = @NO;
        }
        if ([k containsString:@"hitusernotedownloadswitch"] ||
            [k containsString:@"notallowdownload"]) {
            value = @NO;
        }
        if ([k containsString:@"usernotedownloadswitch"] ||
            [k containsString:@"shareimagesaveenable"] ||
            [k containsString:@"allowdownload"] ||
            [k containsString:@"disablewatermark"] ||
            [k isEqualToString:@"isflowdownloadswitchon"]) {
            value = @YES;
        }
    }
    if (orig_cfg_setValue) orig_cfg_setValue(self, _cmd, value, key);
}

static BOOL XHSNameLooksNoteMedia(const char *name) {
    if (!name) return NO;
    return strstr(name, "Note") || strstr(name, "Video") || strstr(name, "Feed") ||
           strstr(name, "XYPH") || strstr(name, "XYVF") || strstr(name, "Share") ||
           strstr(name, "Media") || strstr(name, "ImageSave");
}

static void XHSInstallMediaSaveConfigHooks(void) {
    Class cfgCls = objc_getClass("XYPHMediaSaveConfig");
    if (cfgCls) {
        XHSPatchKnownClass(cfgCls);
        Method m = class_getInstanceMethod(cfgCls, @selector(setValue:forKey:));
        if (m) {
            IMP cur = method_getImplementation(m);
            if (cur != (IMP)hook_cfg_setValue) {
                orig_cfg_setValue = (void *)cur;
                method_setImplementation(m, (IMP)hook_cfg_setValue);
                LOG(@"XYPHMediaSaveConfig setValue:forKey: hooked");
            }
        }
    }

    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    unsigned g = 0, s = 0;
    for (unsigned int i = 0; i < n && (g < 32 || s < 32); i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!XHSNameLooksNoteMedia(name)) continue;

        Method gm = class_getInstanceMethod(cls, sel_registerName("mediaSaveConfig"));
        if (gm && g < 32) {
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
        if (sm && s < 32) {
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
    LOG(@"mediaSaveConfig get=%u set=%u", g, s);
}

#pragma mark - ctor

__attribute__((constructor))
static void XHSInit(void) {
    @autoreleasepool {
        if (!XHSIsTarget()) return;
        LOG(@"v4 load pid=%d", getpid());

        XHSInstallClassHooks();
        XHSInstallJSONHook();
        XHSInstallSessionHook();
        XHSInstallMediaSaveConfigHooks();

        // one delayed pass after Swift classes register
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSPatchKnownClass(objc_getClass("XYPHMediaSaveConfig"));
            XHSPatchKnownClass(objc_getClass("_TtC18XYNegativeFeedback12SaveProvider"));
            XHSPatchKnownClass(objc_getClass("_TtC12XYNoteModule16ImageSaveService"));
            XHSInstallMediaSaveConfigHooks();
            LOG(@"v4 delayed patch");
        });
    }
}
