//
// discover.dylib — 小红书：解锁别人帖子的图片/视频保存
// Bundle: com.xingin.discover | 可执行名: discover | 对照: 9.38.1
//
// 用户反馈「作者关闭下载」仍出现：
//   真正拦截不只是 disableSave，还有作者隐私侧：
//     hitUserNoteDownloadSwitch / hitRacingUserNoteDownloadSwitch
//     userNoteDownloadSwitch / isFlowDownloadSwitchOn
//     checkShowCloseNoteDownloadSwitchToast  → 弹「作者关闭下载」类 toast
//   以及 media_save_config.disable_save / SaveProvider.enable
//
// 策略：上述开关全部强制为「允许下载」，并干掉关闭下载 toast。
// 不加悬浮按钮、不截图。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <unistd.h>

static const BOOL kXHSVerbose = NO;
#define XHSLog(fmt, ...) do { if (kXHSVerbose) NSLog(@"[XHSMediaSave] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - Stubs

static BOOL XHS_retNO(id self, SEL _cmd) { (void)self;(void)_cmd; return NO; }
static BOOL XHS_retYES(id self, SEL _cmd) { (void)self;(void)_cmd; return YES; }
static id XHS_retYesNum(id self, SEL _cmd) { (void)self;(void)_cmd; return @YES; }
static id XHS_retNoNum(id self, SEL _cmd) { (void)self;(void)_cmd; return @NO; }
static void XHS_retVoid(id self, SEL _cmd) { (void)self;(void)_cmd; }
static void XHS_retVoid1(id self, SEL _cmd, id a) { (void)self;(void)_cmd;(void)a; }
static void XHS_setBoolIgnore(id self, SEL _cmd, BOOL v) { (void)self;(void)_cmd;(void)v; }
static void XHS_setIdIgnore(id self, SEL _cmd, id v) { (void)self;(void)_cmd;(void)v; }

// 带 1 个 id 参数、返回 BOOL 的 getter（如 getNotAllowDownloadMyVideos:）
static BOOL XHS_retNO_id(id self, SEL _cmd, id a) { (void)self;(void)_cmd;(void)a; return NO; }
static BOOL XHS_retYES_id(id self, SEL _cmd, id a) { (void)self;(void)_cmd;(void)a; return YES; }

static void XHSSetIMP(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, imp);
    XHSLog(@"setIMP %s -%s", class_getName(cls), sel_getName(sel));
}

static void XHSForceBoolGetter(Class cls, const char *name, BOOL value) {
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    if (!t) return;
    unsigned argc = method_getNumberOfArguments(m); // self,_cmd,...
    if (t[0] == 'B' || t[0] == 'c') {
        if (argc == 2) {
            method_setImplementation(m, value ? (IMP)XHS_retYES : (IMP)XHS_retNO);
        } else if (argc == 3) {
            method_setImplementation(m, value ? (IMP)XHS_retYES_id : (IMP)XHS_retNO_id);
        } else {
            // 用 block 兜底
            if (value) {
                method_setImplementation(m, imp_implementationWithBlock(^BOOL(id s, ...){ (void)s; return YES; }));
            } else {
                method_setImplementation(m, imp_implementationWithBlock(^BOOL(id s, ...){ (void)s; return NO; }));
            }
        }
        XHSLog(@"BOOL %s -%s -> %d argc=%u", class_getName(cls), name, (int)value, argc);
    } else if (t[0] == '@') {
        method_setImplementation(m, value ? (IMP)XHS_retYesNum : (IMP)XHS_retNoNum);
        XHSLog(@"id %s -%s -> %@", class_getName(cls), name, value ? @"YES" : @"NO");
    }
}

static void XHSForceVoid(Class cls, const char *name) {
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    unsigned argc = method_getNumberOfArguments(m);
    if (argc <= 2) method_setImplementation(m, (IMP)XHS_retVoid);
    else method_setImplementation(m, (IMP)XHS_retVoid1);
    XHSLog(@"void-nop %s -%s", class_getName(cls), name);
}

static void XHSBlockSetter(Class cls, const char *name) {
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    if (!t) return;
    // 粗暴：按第二个参数类型
    if (strstr(t, "B") || strstr(t, "c")) {
        method_setImplementation(m, (IMP)XHS_setBoolIgnore);
    } else {
        method_setImplementation(m, (IMP)XHS_setIdIgnore);
    }
}

#pragma mark - Patch class

static void XHSPatchClass(Class cls) {
    if (!cls) return;

    // ===== 图片/媒体保存配置 =====
    // disableSave=YES → 禁止；强制 NO
    XHSForceBoolGetter(cls, "disableSave", NO);
    XHSForceBoolGetter(cls, "isDisableSave", NO);
    XHSForceBoolGetter(cls, "forbidCopy", NO);
    XHSForceBoolGetter(cls, "disableCopy", NO);
    XHSForceBoolGetter(cls, "disableCopyAction", NO);
    XHSForceBoolGetter(cls, "disableWatermark", YES);
    XHSForceBoolGetter(cls, "disableWatermarkWhenSavingAlbum", YES);
    XHSBlockSetter(cls, "setDisableSave:");
    XHSBlockSetter(cls, "setForbidCopy:");

    XHSForceBoolGetter(cls, "shareImageSaveEnable", YES);
    XHSBlockSetter(cls, "setShareImageSaveEnable:");

    // ===== 作者隐私：笔记下载开关（「作者关闭下载」核心）=====
    // hit* = 命中「关闭下载」→ 应强制未命中 NO
    XHSForceBoolGetter(cls, "hitUserNoteDownloadSwitch", NO);
    XHSForceBoolGetter(cls, "hitRacingUserNoteDownloadSwitch", NO);

    // userNoteDownloadSwitch / isFlowDownloadSwitchOn = 允许下载 → YES
    XHSForceBoolGetter(cls, "userNoteDownloadSwitch", YES);
    XHSForceBoolGetter(cls, "isFlowDownloadSwitchOn", YES);
    XHSForceBoolGetter(cls, "flowDownloadSwitchOn", YES);
    XHSForceBoolGetter(cls, "isFlowDownloadSwitchOn", YES);

    // 干掉「关闭下载」toast
    XHSForceVoid(cls, "checkShowCloseNoteDownloadSwitchToast");

    // 视频：不允许下载我的视频 → NO
    XHSForceBoolGetter(cls, "notAllowDownloadMyVideos", NO);
    XHSForceBoolGetter(cls, "isNotAllowDownloadMyVideos", NO);
    XHSForceBoolGetter(cls, "notAllowDownloadMyVideosSwitchOn", NO);
    XHSBlockSetter(cls, "setNotAllowDownloadMyVideos:");
    // getNotAllowDownloadMyVideos:
    XHSForceBoolGetter(cls, "getNotAllowDownloadMyVideos:", NO);

    // 通用 allow
    XHSForceBoolGetter(cls, "allowDownload", YES);
    XHSForceBoolGetter(cls, "isAllowDownload", YES);
    XHSForceBoolGetter(cls, "canDownload", YES);
    XHSForceBoolGetter(cls, "canSaveVideo", YES);
    XHSForceBoolGetter(cls, "enableSaveVideo", YES);
    XHSForceBoolGetter(cls, "shareVideoSaveEnable", YES);
    XHSForceBoolGetter(cls, "userVideoDownloadSwitch", YES);
    XHSForceBoolGetter(cls, "videoDownloadSwitch", YES);
    XHSForceBoolGetter(cls, "settingGeneralAllowDownloadMyVideos", YES);

    const char *name = class_getName(cls);
    if (!name) return;

    // SaveProvider.enable 等
    if (strstr(name, "SaveProvider") ||
        strstr(name, "NegativeFeedback") ||
        strstr(name, "ImageSave") ||
        strstr(name, "SaveImage") ||
        strstr(name, "NoteSave") ||
        strstr(name, "MediaSave") ||
        strstr(name, "VideoSave") ||
        strstr(name, "DownloadSwitch") ||
        strstr(name, "NoteDownload") ||
        strstr(name, "FlowDownload")) {
        XHSForceBoolGetter(cls, "enable", YES);
        XHSForceBoolGetter(cls, "isEnable", YES);
        XHSForceBoolGetter(cls, "isEnabled", YES);
    }
}

static BOOL XHSInterestingName(const char *name) {
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
           strstr(name, "Downloader") ||
           strstr(name, "XYVFVideo") ||
           strstr(name, "DownloadSwitch") ||
           strstr(name, "NoteDownload") ||
           strstr(name, "FlowDownload") ||
           strstr(name, "XYPHSetting") ||
           strstr(name, "Authority") ||
           strstr(name, "Privacy") ||
           strstr(name, "FeedbackFloating") ||
           strstr(name, "LongPress");
}

static void XHSScanAndPatch(void) {
    static const char *kKnown[] = {
        "XYPHMediaSaveConfig",
        "XYVFVideoDownloaderManager",
        "XYNoteFeedbackFloatingConfig",
        NULL
    };
    for (const char **p = kKnown; *p; p++) {
        XHSPatchClass(objc_getClass(*p));
    }

    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        BOOL byName = XHSInterestingName(name);
        BOOL bySel =
            class_getInstanceMethod(cls, sel_registerName("disableSave")) ||
            class_getInstanceMethod(cls, sel_registerName("setDisableSave:")) ||
            class_getInstanceMethod(cls, sel_registerName("hitUserNoteDownloadSwitch")) ||
            class_getInstanceMethod(cls, sel_registerName("hitRacingUserNoteDownloadSwitch")) ||
            class_getInstanceMethod(cls, sel_registerName("userNoteDownloadSwitch")) ||
            class_getInstanceMethod(cls, sel_registerName("isFlowDownloadSwitchOn")) ||
            class_getInstanceMethod(cls, sel_registerName("checkShowCloseNoteDownloadSwitchToast")) ||
            class_getInstanceMethod(cls, sel_registerName("notAllowDownloadMyVideos")) ||
            class_getInstanceMethod(cls, sel_registerName("shareImageSaveEnable")) ||
            class_getInstanceMethod(cls, sel_registerName("mediaSaveConfig"));
        if (byName || bySel) XHSPatchClass(cls);
    }
    free(list);
    XHSLog(@"scan done %u", n);
}

#pragma mark - KVC / JSON 字段改写

static void (*orig_setValue)(id, SEL, id, NSString *);
static void hook_setValue(id self, SEL _cmd, id value, NSString *key) {
    if (!key) {
        if (orig_setValue) orig_setValue(self, _cmd, value, key);
        return;
    }
    // 禁止类
    if ([key isEqualToString:@"disableSave"] ||
        [key isEqualToString:@"disable_save"] ||
        [key isEqualToString:@"forbidCopy"] ||
        [key isEqualToString:@"forbid_copy"] ||
        [key isEqualToString:@"notAllowDownloadMyVideos"] ||
        [key isEqualToString:@"not_allow_download_my_videos"] ||
        [key isEqualToString:@"hitUserNoteDownloadSwitch"] ||
        [key isEqualToString:@"hitRacingUserNoteDownloadSwitch"] ||
        [key isEqualToString:@"privacyCloseNoteDownload"] ||
        [key isEqualToString:@"closeNoteDownload"]) {
        value = @NO;
    }
    // 允许类
    else if ([key isEqualToString:@"shareImageSaveEnable"] ||
             [key isEqualToString:@"share_image_save_enable"] ||
             [key isEqualToString:@"shareVideoSaveEnable"] ||
             [key isEqualToString:@"allowDownload"] ||
             [key isEqualToString:@"allow_download"] ||
             [key isEqualToString:@"userNoteDownloadSwitch"] ||
             [key isEqualToString:@"user_note_download_switch"] ||
             [key isEqualToString:@"user_video_download_switch"] ||
             [key isEqualToString:@"userVideoDownloadSwitch"] ||
             [key isEqualToString:@"video_download_switch"] ||
             [key isEqualToString:@"videoDownloadSwitch"] ||
             [key isEqualToString:@"isFlowDownloadSwitchOn"] ||
             [key isEqualToString:@"flow_download_switch"] ||
             [key isEqualToString:@"disableWatermark"] ||
             [key isEqualToString:@"disable_watermark"] ||
             [key isEqualToString:@"disableWatermarkWhenSavingAlbum"]) {
        value = @YES;
    }

    if (orig_setValue) orig_setValue(self, _cmd, value, key);
    else {
        struct objc_super sup = { self, class_getSuperclass(object_getClass(self)) };
        ((void (*)(struct objc_super *, SEL, id, NSString *))objc_msgSendSuper)(&sup, _cmd, value, key);
    }
}

// 更狠：hook NSObject 的 setValue:forKey:（只改关键 key，其它原样）
static void XHSHookNSObjectKVC(void) {
    Class cls = objc_getClass("NSObject");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(setValue:forKey:));
    if (!m) return;
    if (!orig_setValue) orig_setValue = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)hook_setValue);
    XHSLog(@"hooked NSObject setValue:forKey:");
}

#pragma mark - mediaSaveConfig 访问后二次清理

static id (*orig_mediaSaveConfig)(id, SEL);
static id hook_mediaSaveConfig(id self, SEL _cmd) {
    id cfg = orig_mediaSaveConfig ? orig_mediaSaveConfig(self, _cmd) : nil;
    if (cfg) {
        XHSPatchClass(object_getClass(cfg));
        @try {
            SEL s = sel_registerName("setDisableSave:");
            if ([cfg respondsToSelector:s]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(cfg, s, NO);
            }
            // 直接 KVC
            [cfg setValue:@NO forKey:@"disableSave"];
        } @catch (__unused NSException *e) {}
    }
    return cfg;
}

static void XHSHookMediaSaveConfigGetters(void) {
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

#pragma mark - Toast 拦截（兜底：文案含「关闭下载」直接吞掉）

static BOOL XHSIsBlockedToast(NSString *text) {
    if (text.length == 0) return NO;
    // 用户看到的「作者关闭下载」及变体
    NSArray *keys = @[
        @"作者关闭下载",
        @"作者已关闭下载",
        @"作者关闭了下载",
        @"关闭了下载",
        @"已关闭下载",
        @"不支持下载",
        @"禁止下载",
        @"不允许下载",
        @"暂不支持下载",
        @"该笔记不支持下载",
        @"作者未开启下载",
        @"下载功能已关闭",
        @"因作者设置",
        @"作者设置了",
    ];
    for (NSString *k in keys) {
        if ([text containsString:k]) return YES;
    }
    // 宽一点：同时含「作者」和「下载」且含关闭/禁止类词
    if ([text containsString:@"下载"] &&
        ([text containsString:@"作者"] || [text containsString:@"笔记"]) &&
        ([text containsString:@"关闭"] || [text containsString:@"禁止"] ||
         [text containsString:@"不支持"] || [text containsString:@"无法"] ||
         [text containsString:@"未开启"])) {
        return YES;
    }
    return NO;
}

// hook 常见 toast 入口
static void (*orig_makeToast)(id, SEL, id);
static void hook_makeToast(id self, SEL _cmd, id msg) {
    NSString *s = nil;
    if ([msg isKindOfClass:[NSString class]]) s = msg;
    else if ([msg respondsToSelector:@selector(description)]) s = [msg description];
    if (XHSIsBlockedToast(s)) {
        XHSLog(@"block toast: %@", s);
        return;
    }
    if (orig_makeToast) orig_makeToast(self, _cmd, msg);
}

static void (*orig_showToast)(id, SEL, id);
static void hook_showToast(id self, SEL _cmd, id msg) {
    NSString *s = [msg isKindOfClass:[NSString class]] ? msg : [msg description];
    if (XHSIsBlockedToast(s)) {
        XHSLog(@"block showToast: %@", s);
        return;
    }
    if (orig_showToast) orig_showToast(self, _cmd, msg);
}

static void (*orig_showWithText)(id, SEL, id);
static void hook_showWithText(id self, SEL _cmd, id msg) {
    NSString *s = [msg isKindOfClass:[NSString class]] ? msg : [msg description];
    if (XHSIsBlockedToast(s)) {
        XHSLog(@"block showWithText: %@", s);
        return;
    }
    if (orig_showWithText) orig_showWithText(self, _cmd, msg);
}

// UIAlertController 也拦一下（少数用 alert）
static id (*orig_alert)(id, SEL, id, id, NSInteger);
static id hook_alert(id self, SEL _cmd, id title, id message, NSInteger style) {
    NSString *t = [title isKindOfClass:[NSString class]] ? title : nil;
    NSString *m = [message isKindOfClass:[NSString class]] ? message : nil;
    if (XHSIsBlockedToast(t) || XHSIsBlockedToast(m)) {
        XHSLog(@"block alert %@ / %@", t, m);
        // 返回一个空 alert 仍可能 present；更好是返回 nil 但类型危险
        // 改为把文案清空后走原逻辑
        message = @"";
        title = @"";
    }
    if (orig_alert) return orig_alert(self, _cmd, title, message, style);
    return nil;
}

static void XHSHookToastMethods(void) {
    // 扫所有类上常见 toast selector
    static const char *sels[] = {
        "makeToast:",
        "showToast:",
        "showToastWithText:",
        "showWithText:",
        "showMessage:",
        "showText:",
        "toast:",
        "showHudWithText:",
        "showHUDWithText:",
        "showTip:",
        "showTips:",
        "showError:",
        "showErrorWithStatus:",
        "showInfoWithStatus:",
        NULL
    };

    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = list[i];
        for (const char **sp = sels; *sp; sp++) {
            SEL sel = sel_registerName(*sp);
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            const char *t = method_getTypeEncoding(m);
            if (!t || t[0] != 'v') continue;
            // 只 hook 参数为 id 的
            if (method_getNumberOfArguments(m) != 3) continue;

            IMP prev = method_getImplementation(m);
            // 按 selector 名分发到不同 orig（简化：统一用 makeToast 风格）
            if (strcmp(*sp, "makeToast:") == 0) {
                if (!orig_makeToast) orig_makeToast = (void *)prev;
                method_setImplementation(m, (IMP)hook_makeToast);
            } else if (strcmp(*sp, "showToast:") == 0 ||
                       strcmp(*sp, "showToastWithText:") == 0 ||
                       strcmp(*sp, "showMessage:") == 0 ||
                       strcmp(*sp, "showText:") == 0 ||
                       strcmp(*sp, "toast:") == 0 ||
                       strcmp(*sp, "showTip:") == 0 ||
                       strcmp(*sp, "showTips:") == 0 ||
                       strcmp(*sp, "showError:") == 0) {
                if (!orig_showToast) orig_showToast = (void *)prev;
                method_setImplementation(m, (IMP)hook_showToast);
            } else if (strcmp(*sp, "showWithText:") == 0 ||
                       strcmp(*sp, "showHudWithText:") == 0 ||
                       strcmp(*sp, "showHUDWithText:") == 0 ||
                       strcmp(*sp, "showErrorWithStatus:") == 0 ||
                       strcmp(*sp, "showInfoWithStatus:") == 0) {
                if (!orig_showWithText) orig_showWithText = (void *)prev;
                method_setImplementation(m, (IMP)hook_showWithText);
            }
        }
    }
    free(list);

    Class alert = objc_getClass("UIAlertController");
    if (alert) {
        Method m = class_getClassMethod(alert, @selector(alertControllerWithTitle:message:preferredStyle:));
        if (m) {
            if (!orig_alert) orig_alert = (void *)method_getImplementation(m);
            method_setImplementation(m, (IMP)hook_alert);
        }
    }
    XHSLog(@"toast hooks installed");
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

#pragma mark - ctor

static void XHSInstallAll(void) {
    XHSScanAndPatch();
    XHSHookNSObjectKVC();
    XHSHookMediaSaveConfigGetters();
    XHSHookToastMethods();
}

__attribute__((constructor))
static void XHSMediaSaveInit(void) {
    @autoreleasepool {
        if (!XHSIsTarget()) return;
        XHSLog(@"loaded pid=%d", getpid());
        XHSInstallAll();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ XHSInstallAll(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSScanAndPatch();
            XHSHookMediaSaveConfigGetters();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSScanAndPatch();
        });
    }
}
