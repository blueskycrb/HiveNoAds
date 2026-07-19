//
// discover.dylib — 小红书：解锁「保存别人帖子的图片 / 视频」
// Bundle: com.xingin.discover | 可执行名: discover | 对照: 9.38.1
//
// 只做一件事：强制打开 App 自带的保存能力。
// 不添加悬浮按钮、不截图、不自己下文件，走原生「保存图片 / 保存视频」。
//
// 用法:
//   TrollFools 注入 discover.dylib → 强杀小红书
//   图文：长按图片 / 分享 →「保存图片」
//   视频：分享面板 / 更多 →「保存视频」（或 App 自带下载入口）
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <unistd.h>

// 调试改 1
static const BOOL kXHSVerbose = NO;
#define XHSLog(fmt, ...) do { if (kXHSVerbose) NSLog(@"[XHSMediaSave] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - IMP stubs

static BOOL XHS_retNO(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return NO;
}
static BOOL XHS_retYES(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return YES;
}
static id XHS_retYesNumber(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @YES;
}
static id XHS_retNoNumber(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @NO;
}
static void XHS_setBoolIgnored(id self, SEL _cmd, BOOL v) {
    (void)self; (void)_cmd; (void)v;
    XHSLog(@"ignore %s %d", sel_getName(_cmd), (int)v);
}
static void XHS_setIdIgnored(id self, SEL _cmd, id v) {
    (void)self; (void)_cmd; (void)v;
    XHSLog(@"ignore id %s", sel_getName(_cmd));
}

static void XHSReplaceBoolGetter(Class cls, SEL sel, BOOL value) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    if (!t) return;
    if (t[0] == 'B' || t[0] == 'c') {
        method_setImplementation(m, value ? (IMP)XHS_retYES : (IMP)XHS_retNO);
        XHSLog(@"BOOL %s -%s -> %d", class_getName(cls), sel_getName(sel), (int)value);
    }
}

static void XHSReplaceNumberGetter(Class cls, SEL sel, BOOL yesValue) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    if (!t) return;
    if (t[0] == '@') {
        method_setImplementation(m, yesValue ? (IMP)XHS_retYesNumber : (IMP)XHS_retNoNumber);
        XHSLog(@"NSNumber %s -%s -> %@", class_getName(cls), sel_getName(sel), yesValue ? @"YES" : @"NO");
    } else if (t[0] == 'B' || t[0] == 'c') {
        method_setImplementation(m, yesValue ? (IMP)XHS_retYES : (IMP)XHS_retNO);
        XHSLog(@"BOOL %s -%s -> %d", class_getName(cls), sel_getName(sel), (int)yesValue);
    }
}

static void XHSBlockBoolSetter(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, (IMP)XHS_setBoolIgnored);
}

static void XHSBlockIdSetter(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, (IMP)XHS_setIdIgnored);
}

// setter 强制写入固定 BOOL（用于 setNotAllowDownloadMyVideos: 等）
static void XHS_setBoolForceNO(id self, SEL _cmd, BOOL v) {
    (void)v;
    // 尽量调用原实现写 NO：这里用关联存储不够，直接忽略 YES 更安全
    XHSLog(@"forceNO %s (was %d)", sel_getName(_cmd), (int)v);
}
static void XHSForceSetterNO(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, (IMP)XHS_setBoolForceNO);
}

#pragma mark - Patch one class

static void XHSPatchSaveFlagsOnClass(Class cls) {
    if (!cls) return;

    // —— 图片 / 通用媒体 ——
    XHSReplaceBoolGetter(cls, sel_registerName("disableSave"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("isDisableSave"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("forbidCopy"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("isForbidCopy"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("disableCopy"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("disableCopyAction"), NO);

    XHSReplaceBoolGetter(cls, sel_registerName("disableWatermark"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("disableWatermarkWhenSavingAlbum"), YES);

    XHSBlockBoolSetter(cls, sel_registerName("setDisableSave:"));
    XHSBlockBoolSetter(cls, sel_registerName("setForbidCopy:"));
    XHSBlockBoolSetter(cls, sel_registerName("setDisableCopy:"));
    XHSBlockBoolSetter(cls, sel_registerName("setDisableCopyAction:"));

    // 分享面板「保存图片」
    XHSReplaceNumberGetter(cls, sel_registerName("shareImageSaveEnable"), YES);
    XHSBlockIdSetter(cls, sel_registerName("setShareImageSaveEnable:"));
    XHSBlockBoolSetter(cls, sel_registerName("setShareImageSaveEnable:"));

    // —— 视频下载权限 ——
    // 设置项 / 笔记侧：不允许下载我的视频 → 强制允许
    XHSReplaceBoolGetter(cls, sel_registerName("notAllowDownloadMyVideos"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("isNotAllowDownloadMyVideos"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("notAllowDownloadMyVideosSwitchOn"), NO);
    XHSReplaceNumberGetter(cls, sel_registerName("notAllowDownloadMyVideos"), NO);
    XHSForceSetterNO(cls, sel_registerName("setNotAllowDownloadMyVideos:"));
    XHSBlockBoolSetter(cls, sel_registerName("setNotAllowDownloadMyVideos:"));

    // 通用 allow / enable download
    XHSReplaceBoolGetter(cls, sel_registerName("allowDownload"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("isAllowDownload"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("enableDownload"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("canDownload"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("canSaveVideo"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("enableSaveVideo"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("videoSaveEnable"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("shareVideoSaveEnable"), YES);
    XHSReplaceNumberGetter(cls, sel_registerName("shareVideoSaveEnable"), YES);
    XHSReplaceNumberGetter(cls, sel_registerName("allowDownload"), YES);

    // user_video_download_switch 等可能以 NSNumber 暴露
    XHSReplaceNumberGetter(cls, sel_registerName("userVideoDownloadSwitch"), YES);
    XHSReplaceNumberGetter(cls, sel_registerName("videoDownloadSwitch"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("userVideoDownloadSwitch"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("videoDownloadSwitch"), YES);

    const char *name = class_getName(cls);
    if (!name) return;

    // SaveProvider / 负反馈 / 媒体保存入口
    if (strstr(name, "SaveProvider") ||
        strstr(name, "NegativeFeedback") ||
        strstr(name, "ImageSave") ||
        strstr(name, "SaveImage") ||
        strstr(name, "NoteSave") ||
        strstr(name, "MediaSave") ||
        strstr(name, "VideoSave") ||
        strstr(name, "VideoDownload") ||
        strstr(name, "Downloader")) {
        XHSReplaceBoolGetter(cls, sel_registerName("enable"), YES);
        XHSReplaceBoolGetter(cls, sel_registerName("isEnable"), YES);
        XHSReplaceBoolGetter(cls, sel_registerName("isEnabled"), YES);
        XHSReplaceNumberGetter(cls, sel_registerName("enable"), YES);
    }
}

static BOOL XHSClassNameInteresting(const char *name) {
    if (!name) return NO;
    return strstr(name, "MediaSave") ||
           strstr(name, "ImageSave") ||
           strstr(name, "SaveConfig") ||
           strstr(name, "SaveProvider") ||
           strstr(name, "NoteImage") ||
           strstr(name, "XYPHNote") ||
           strstr(name, "XYPHMedia") ||
           strstr(name, "NegativeFeedback") ||
           strstr(name, "NoteSave") ||
           strstr(name, "ShareInfo") ||
           strstr(name, "SaveCell") ||
           strstr(name, "VideoSave") ||
           strstr(name, "VideoDownload") ||
           strstr(name, "DownloaderManager") ||
           strstr(name, "XYVFVideo") ||
           strstr(name, "VideoDownloader") ||
           strstr(name, "settingGeneral") ||
           strstr(name, "Privacy") ||
           strstr(name, "DownloadMyVideo");
}

static void XHSScanAndPatch(void) {
    XHSPatchSaveFlagsOnClass(objc_getClass("XYPHMediaSaveConfig"));
    XHSPatchSaveFlagsOnClass(objc_getClass("XYVFVideoDownloaderManager"));

    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        BOOL byName = XHSClassNameInteresting(name);
        BOOL bySel =
            class_getInstanceMethod(cls, sel_registerName("disableSave")) ||
            class_getInstanceMethod(cls, sel_registerName("setDisableSave:")) ||
            class_getInstanceMethod(cls, sel_registerName("shareImageSaveEnable")) ||
            class_getInstanceMethod(cls, sel_registerName("mediaSaveConfig")) ||
            class_getInstanceMethod(cls, sel_registerName("notAllowDownloadMyVideos")) ||
            class_getInstanceMethod(cls, sel_registerName("setNotAllowDownloadMyVideos:")) ||
            class_getInstanceMethod(cls, sel_registerName("allowDownload")) ||
            class_getInstanceMethod(cls, sel_registerName("canSaveVideo"));
        if (byName || bySel) {
            XHSPatchSaveFlagsOnClass(cls);
        }
    }
    free(list);
    XHSLog(@"scan done classes=%u", n);
}

#pragma mark - KVC on config models

static void (*orig_setValue_forKey)(id, SEL, id, NSString *);
static void hook_setValue_forKey(id self, SEL _cmd, id value, NSString *key) {
    if ([key isEqualToString:@"disableSave"] ||
        [key isEqualToString:@"disable_save"] ||
        [key isEqualToString:@"forbidCopy"] ||
        [key isEqualToString:@"forbid_copy"] ||
        [key isEqualToString:@"notAllowDownloadMyVideos"] ||
        [key isEqualToString:@"not_allow_download_my_videos"]) {
        value = @NO;
    } else if ([key isEqualToString:@"shareImageSaveEnable"] ||
               [key isEqualToString:@"share_image_save_enable"] ||
               [key isEqualToString:@"shareVideoSaveEnable"] ||
               [key isEqualToString:@"allowDownload"] ||
               [key isEqualToString:@"allow_download"] ||
               [key isEqualToString:@"user_video_download_switch"] ||
               [key isEqualToString:@"userVideoDownloadSwitch"] ||
               [key isEqualToString:@"video_download_switch"] ||
               [key isEqualToString:@"videoDownloadSwitch"]) {
        value = @YES;
    } else if ([key isEqualToString:@"disableWatermark"] ||
               [key isEqualToString:@"disable_watermark"] ||
               [key isEqualToString:@"disableWatermarkWhenSavingAlbum"]) {
        value = @YES;
    }
    if (orig_setValue_forKey) {
        orig_setValue_forKey(self, _cmd, value, key);
    } else {
        struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
        ((void (*)(struct objc_super *, SEL, id, NSString *))objc_msgSendSuper)(&sup, _cmd, value, key);
    }
}

static void XHSHookKVCOnClass(const char *cname) {
    Class cls = objc_getClass(cname);
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(setValue:forKey:));
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (!orig_setValue_forKey) orig_setValue_forKey = (void *)old;
    class_replaceMethod(cls, @selector(setValue:forKey:),
                        (IMP)hook_setValue_forKey,
                        method_getTypeEncoding(m));
    XHSLog(@"KVC hook %s", cname);
}

static void XHSTryHookConfigKVC(void) {
    XHSHookKVCOnClass("XYPHMediaSaveConfig");
}

#pragma mark - mediaSaveConfig accessor

static id (*orig_mediaSaveConfig)(id, SEL);
static id hook_mediaSaveConfig(id self, SEL _cmd) {
    id cfg = orig_mediaSaveConfig ? orig_mediaSaveConfig(self, _cmd) : nil;
    if (cfg) {
        XHSPatchSaveFlagsOnClass(object_getClass(cfg));
        @try {
            if ([cfg respondsToSelector:sel_registerName("setDisableSave:")]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(cfg, sel_registerName("setDisableSave:"), NO);
            }
        } @catch (__unused NSException *e) {}
    }
    return cfg;
}

static void XHSHookMediaSaveConfigAccessors(void) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = list[i];
        Method m = class_getInstanceMethod(cls, sel_registerName("mediaSaveConfig"));
        if (!m) continue;
        const char *t = method_getTypeEncoding(m);
        if (!t || t[0] != '@') continue;
        IMP prev = method_getImplementation(m);
        if (!orig_mediaSaveConfig) orig_mediaSaveConfig = (void *)prev;
        method_setImplementation(m, (IMP)hook_mediaSaveConfig);
    }
    free(list);
}

#pragma mark - notAllowDownloadMyVideos 读写全拦

static BOOL (*orig_notAllow)(id, SEL);
static BOOL hook_notAllow(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    if (orig_notAllow) {
        // still return NO always
    }
    return NO;
}
static void (*orig_setNotAllow)(id, SEL, BOOL);
static void hook_setNotAllow(id self, SEL _cmd, BOOL v) {
    (void)v;
    if (orig_setNotAllow) orig_setNotAllow(self, _cmd, NO);
}

static void XHSHookNotAllowDownloadSelectors(void) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = list[i];
        Method g = class_getInstanceMethod(cls, sel_registerName("notAllowDownloadMyVideos"));
        if (g) {
            const char *t = method_getTypeEncoding(g);
            if (t && (t[0] == 'B' || t[0] == 'c')) {
                IMP prev = method_getImplementation(g);
                if (!orig_notAllow) orig_notAllow = (void *)prev;
                method_setImplementation(g, (IMP)hook_notAllow);
            }
        }
        Method s = class_getInstanceMethod(cls, sel_registerName("setNotAllowDownloadMyVideos:"));
        if (s) {
            IMP prev = method_getImplementation(s);
            if (!orig_setNotAllow) orig_setNotAllow = (void *)prev;
            method_setImplementation(s, (IMP)hook_setNotAllow);
        }
        // getNotAllowDownloadMyVideos: 有时是带参数的
        Method g2 = class_getInstanceMethod(cls, sel_registerName("getNotAllowDownloadMyVideos:"));
        if (g2) {
            const char *t = method_getTypeEncoding(g2);
            // 返回 BOOL 的简单替换可能签名不匹配；仅当返回 B/c 且 3 参数时处理
            if (t && (t[0] == 'B' || t[0] == 'c')) {
                method_setImplementation(g2, imp_implementationWithBlock(^BOOL(id _self, id arg) {
                    (void)_self; (void)arg;
                    return NO;
                }));
            }
        }
    }
    free(list);
}

#pragma mark - Target

static BOOL XHSIsTarget(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid isEqualToString:@"com.xingin.discover"]) return YES;
    NSString *exe = [[NSBundle mainBundle].executablePath lastPathComponent] ?: @"";
    if ([exe isEqualToString:@"discover"]) return YES;
    if (bid.length == 0) return YES;
    return NO;
}

#pragma mark - Constructor

__attribute__((constructor))
static void XHSMediaSaveInit(void) {
    @autoreleasepool {
        if (!XHSIsTarget()) return;
        XHSLog(@"loaded pid=%d bid=%@", getpid(), [NSBundle mainBundle].bundleIdentifier);

        XHSScanAndPatch();
        XHSTryHookConfigKVC();
        XHSHookMediaSaveConfigAccessors();
        XHSHookNotAllowDownloadSelectors();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSScanAndPatch();
            XHSTryHookConfigKVC();
            XHSHookMediaSaveConfigAccessors();
            XHSHookNotAllowDownloadSelectors();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSScanAndPatch();
            XHSHookMediaSaveConfigAccessors();
            XHSHookNotAllowDownloadSelectors();
        });
    }
}
