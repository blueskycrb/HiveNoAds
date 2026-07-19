//
// discover.dylib — 小红书：解锁别人帖子图片/视频保存（性能优先）
// Bundle: com.xingin.discover | 可执行名: discover | 对照: 9.38.1
//
// v3 重要变更（修卡顿 + 仍下不了）:
//   - 删除 NSObject 全局 setValue:forKey:（这是卡死滑动的主因）
//   - 删除全 class list 扫 toast / 多次全量重扫
//   - 启动只做一次轻量定点 hook
//   - 在 NSURLSession 回调里改写笔记 JSON：disable_save / 下载开关
//   - 用户点「保存」时若仍被拦，尽量放行已知保存入口
//
// 无悬浮按钮、不截图。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <pthread.h>

static const BOOL kVerbose = NO;
#define LOG(fmt, ...) do { if (kVerbose) NSLog(@"[XHSMediaSave] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - tiny helpers

static BOOL XHSIsTarget(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    NSString *exe = [[NSBundle mainBundle].executablePath lastPathComponent] ?: @"";
    cached = ([bid isEqualToString:@"com.xingin.discover"] ||
              [exe isEqualToString:@"discover"] ||
              bid.length == 0) ? 1 : 0;
    return cached;
}

static BOOL XHS_retNO(id s, SEL c) { (void)s;(void)c; return NO; }
static BOOL XHS_retYES(id s, SEL c) { (void)s;(void)c; return YES; }
static id   XHS_retYesObj(id s, SEL c) { (void)s;(void)c; return @YES; }
static id   XHS_retNoObj(id s, SEL c) { (void)s;(void)c; return @NO; }
static void XHS_void0(id s, SEL c) { (void)s;(void)c; }
static void XHS_setBoolDrop(id s, SEL c, BOOL v) { (void)s;(void)c;(void)v; }

static void XHSPatchBool(Class cls, const char *selName, BOOL value) {
    if (!cls) return;
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
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName(selName));
    if (!m) return;
    if (method_getNumberOfArguments(m) == 2) {
        method_setImplementation(m, (IMP)XHS_void0);
        LOG(@"nop %s -%s", class_getName(cls), selName);
    }
}

static void XHSPatchSetterDrop(Class cls, const char *selName) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel_registerName(selName));
    if (!m) return;
    method_setImplementation(m, (IMP)XHS_setBoolDrop);
}

static void XHSPatchKnownClass(Class cls) {
    if (!cls) return;
    // 禁止保存 → 允许
    XHSPatchBool(cls, "disableSave", NO);
    XHSPatchBool(cls, "isDisableSave", NO);
    XHSPatchBool(cls, "forbidCopy", NO);
    XHSPatchBool(cls, "disableCopy", NO);
    XHSPatchSetterDrop(cls, "setDisableSave:");
    XHSPatchSetterDrop(cls, "setForbidCopy:");

    // 作者关闭下载相关（命中=NO，开关=YES）
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
    XHSPatchBool(cls, "enable", YES); // SaveProvider 等

    XHSPatchVoid(cls, "checkShowCloseNoteDownloadSwitchToast");
    XHSPatchSetterDrop(cls, "setNotAllowDownloadMyVideos:");
}

#pragma mark - 一次定点 hook（不反复全表扫描）

static void XHSInstallClassHooks(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 1) 已知类名直接 hook
        const char *known[] = {
            "XYPHMediaSaveConfig",
            "XYVFVideoDownloaderManager",
            "XYNoteFeedbackFloatingConfig",
            "_TtC18XYNegativeFeedback12SaveProvider",
            "SaveProvider",
            NULL
        };
        for (const char **p = known; *p; p++) {
            XHSPatchKnownClass(objc_getClass(*p));
        }

        // 2) 单次扫描：只处理「带关键 selector」的类，做完即停
        //    不做 toast 全表 hook，不重复扫
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
                class_getInstanceMethod(cls, sel_registerName("shareImageSaveEnable"))) {
                XHSPatchKnownClass(cls);
                patched++;
                // 安全上限，避免异常环境扫爆
                if (patched > 80) break;
            }
        }
        free(list);
        LOG(@"class hooks done, patched=%u / %u", patched, n);
    });
}

#pragma mark - JSON 响应改写（真正让「作者关闭下载」字段变允许）

// 仅做 ASCII 子串替换，避免解析整棵 JSON 树（快）
static NSData *XHSPatchNoteJSON(NSData *data) {
    if (data.length < 32 || data.length > 8 * 1024 * 1024) return data;

    // 快速过滤：不像笔记/保存相关响应就跳过
    static NSData *k1, *k2, *k3, *k4, *k5, *k6, *k7, *k8;
    static dispatch_once_t onceKeys;
    dispatch_once(&onceKeys, ^{
        k1 = [@"disable_save" dataUsingEncoding:NSUTF8StringEncoding];
        k2 = [@"disableSave" dataUsingEncoding:NSUTF8StringEncoding];
        k3 = [@"media_save_config" dataUsingEncoding:NSUTF8StringEncoding];
        k4 = [@"user_video_download_switch" dataUsingEncoding:NSUTF8StringEncoding];
        k5 = [@"userNoteDownloadSwitch" dataUsingEncoding:NSUTF8StringEncoding];
        k6 = [@"hitUserNoteDownloadSwitch" dataUsingEncoding:NSUTF8StringEncoding];
        k7 = [@"notAllowDownloadMyVideos" dataUsingEncoding:NSUTF8StringEncoding];
        k8 = [@"shareImageSaveEnable" dataUsingEncoding:NSUTF8StringEncoding];
    });
    NSRange full = NSMakeRange(0, data.length);
    if ([data rangeOfData:k1 options:0 range:full].location == NSNotFound &&
        [data rangeOfData:k2 options:0 range:full].location == NSNotFound &&
        [data rangeOfData:k3 options:0 range:full].location == NSNotFound &&
        [data rangeOfData:k4 options:0 range:full].location == NSNotFound &&
        [data rangeOfData:k5 options:0 range:full].location == NSNotFound &&
        [data rangeOfData:k6 options:0 range:full].location == NSNotFound &&
        [data rangeOfData:k7 options:0 range:full].location == NSNotFound &&
        [data rangeOfData:k8 options:0 range:full].location == NSNotFound) {
        return data;
    }

    NSMutableData *md = [data mutableCopy];
    NSString *s = [[NSString alloc] initWithData:md encoding:NSUTF8StringEncoding];
    if (!s) return data;

    // 布尔 true/false 与 1/0 都改
    NSArray<NSArray<NSString *> *> *pairs = @[
        // 禁止 → 允许
        @[@"\"disable_save\":true",  @"\"disable_save\":false"],
        @[@"\"disable_save\": true", @"\"disable_save\": false"],
        @[@"\"disableSave\":true",   @"\"disableSave\":false"],
        @[@"\"disableSave\": true",  @"\"disableSave\": false"],
        @[@"\"disable_save\":1",     @"\"disable_save\":0"],
        @[@"\"disableSave\":1",      @"\"disableSave\":0"],

        @[@"\"forbid_copy\":true",   @"\"forbid_copy\":false"],
        @[@"\"forbidCopy\":true",    @"\"forbidCopy\":false"],

        // 命中「关闭下载」→ 未命中
        @[@"\"hitUserNoteDownloadSwitch\":true",  @"\"hitUserNoteDownloadSwitch\":false"],
        @[@"\"hitUserNoteDownloadSwitch\": true", @"\"hitUserNoteDownloadSwitch\": false"],
        @[@"\"hitRacingUserNoteDownloadSwitch\":true",  @"\"hitRacingUserNoteDownloadSwitch\":false"],
        @[@"\"hitRacingUserNoteDownloadSwitch\": true", @"\"hitRacingUserNoteDownloadSwitch\": false"],

        // 不允许下载我的视频 → 允许
        @[@"\"notAllowDownloadMyVideos\":true",  @"\"notAllowDownloadMyVideos\":false"],
        @[@"\"not_allow_download_my_videos\":true", @"\"not_allow_download_my_videos\":false"],
        @[@"\"notAllowDownloadMyVideos\":1", @"\"notAllowDownloadMyVideos\":0"],

        // 开关类：强制开
        @[@"\"userNoteDownloadSwitch\":false",  @"\"userNoteDownloadSwitch\":true"],
        @[@"\"userNoteDownloadSwitch\": false", @"\"userNoteDownloadSwitch\": true"],
        @[@"\"user_note_download_switch\":false", @"\"user_note_download_switch\":true"],
        @[@"\"user_video_download_switch\":false", @"\"user_video_download_switch\":true"],
        @[@"\"user_video_download_switch\": false", @"\"user_video_download_switch\": true"],
        @[@"\"userVideoDownloadSwitch\":false", @"\"userVideoDownloadSwitch\":true"],
        @[@"\"isFlowDownloadSwitchOn\":false", @"\"isFlowDownloadSwitchOn\":true"],
        @[@"\"shareImageSaveEnable\":false", @"\"shareImageSaveEnable\":true"],
        @[@"\"share_image_save_enable\":false", @"\"share_image_save_enable\":true"],
        @[@"\"allowDownload\":false", @"\"allowDownload\":true"],
        @[@"\"allow_download\":false", @"\"allow_download\":true"],
        @[@"\"mobile_download_switch\":false", @"\"mobile_download_switch\":true"],
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
    LOG(@"json patched %lu -> %lu", (unsigned long)data.length, (unsigned long)nd.length);
    return nd ?: data;
}

#pragma mark - NSURLSession data task hook（轻量）

// 只 hook -[NSURLSession dataTaskWithRequest:completionHandler:]
// 在 completion 里改 data，不影响主线程滑动

typedef void (^XHSDataCompletion)(NSData *, NSURLResponse *, NSError *);

static id (*orig_dataTask)(id, SEL, NSURLRequest *, XHSDataCompletion);

static id hook_dataTask(id self, SEL _cmd, NSURLRequest *req, XHSDataCompletion completion) {
    if (!completion) {
        return orig_dataTask(self, _cmd, req, completion);
    }
    XHSDataCompletion wrapped = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSData *patched = data;
        if (!err && data.length) {
            @try { patched = XHSPatchNoteJSON(data); }
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

// 部分请求走 dataTaskWithRequest: 无 block，或 ephemeral 子类
// 再 hook NSConcreteURLSession 若存在
static void XHSInstallSessionHookSubclasses(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // __NSCFURLSession 等
        unsigned int n = 0;
        Class *list = objc_copyClassList(&n);
        if (!list) return;
        SEL sel = @selector(dataTaskWithRequest:completionHandler:);
        unsigned hooked = 0;
        for (unsigned int i = 0; i < n && hooked < 6; i++) {
            Class cls = list[i];
            const char *name = class_getName(cls);
            if (!name) continue;
            if (!strstr(name, "URLSession") && !strstr(name, "NSURLSession")) continue;
            Method m = class_getInstanceMethod(cls, sel);
            if (!m) continue;
            // 若实现与已 hook 的相同则跳过
            IMP cur = method_getImplementation(m);
            if (cur == (IMP)hook_dataTask) continue;
            // 只在还没保存 orig 时用第一个；子类若有自己的 IMP 也包一层
            if (!orig_dataTask) orig_dataTask = (void *)cur;
            // 子类独立 orig：用关联存储太重；统一走到 hook_dataTask 再调 orig_dataTask
            // 若子类 IMP != orig，需要各自保存 — 简化：只 hook NSURLSession 基类即可覆盖多数
            if (cls == [NSURLSession class] || strstr(name, "NSURLSession")) {
                method_setImplementation(m, (IMP)hook_dataTask);
                hooked++;
            }
        }
        free(list);
        LOG(@"session subclasses hooked=%u", hooked);
    });
}

#pragma mark - mediaSaveConfig 访问时强制清 disableSave（定点）

static id (*orig_msc)(id, SEL);
static id hook_msc(id self, SEL _cmd) {
    id cfg = orig_msc ? orig_msc(self, _cmd) : nil;
    if (!cfg) return cfg;
    Class c = object_getClass(cfg);
    XHSPatchKnownClass(c);
    @try {
        SEL s = sel_registerName("setDisableSave:");
        if ([cfg respondsToSelector:s]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(cfg, s, NO);
        }
    } @catch (__unused NSException *e) {}
    return cfg;
}

static void XHSInstallMediaSaveConfigGetter(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 只 hook 几个名字像 Note / Video 的类上的 mediaSaveConfig
        unsigned int n = 0;
        Class *list = objc_copyClassList(&n);
        if (!list) return;
        unsigned hooked = 0;
        for (unsigned int i = 0; i < n && hooked < 30; i++) {
            Class cls = list[i];
            Method m = class_getInstanceMethod(cls, sel_registerName("mediaSaveConfig"));
            if (!m) continue;
            const char *t = method_getTypeEncoding(m);
            if (!t || t[0] != '@') continue;
            IMP prev = method_getImplementation(m);
            if (!orig_msc) orig_msc = (void *)prev;
            method_setImplementation(m, (IMP)hook_msc);
            hooked++;
        }
        free(list);
        LOG(@"mediaSaveConfig getters=%u", hooked);
    });
}

#pragma mark - ctor

__attribute__((constructor))
static void XHSInit(void) {
    @autoreleasepool {
        if (!XHSIsTarget()) return;
        LOG(@"v3 load pid=%d", getpid());

        // 全部 once，不在滑动路径上反复扫
        XHSInstallClassHooks();
        XHSInstallSessionHook();
        XHSInstallSessionHookSubclasses();
        XHSInstallMediaSaveConfigGetter();

        // 仅一次延迟补丁：等 Swift 类注册（不扫 toast、不 hook NSObject）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // 再试已知类（once 内已保护 class hooks；这里只补 known 名）
            XHSPatchKnownClass(objc_getClass("XYPHMediaSaveConfig"));
            XHSPatchKnownClass(objc_getClass("_TtC18XYNegativeFeedback12SaveProvider"));
            XHSInstallMediaSaveConfigGetter();
            LOG(@"v3 delayed patch");
        });
    }
}
