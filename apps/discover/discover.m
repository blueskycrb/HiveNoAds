//
// discover.dylib — 小红书：解锁「保存别人帖子的图片」
// Bundle: com.xingin.discover | 可执行名: discover | 对照: 9.38.1
//
// 只做一件事：强制打开 App 自带的保存能力（disableSave / 分享面板保存入口）。
// 不添加任何悬浮按钮、不截图、不替代原生 UI。
//
// 用法:
//   TrollFools 注入 discover.dylib → 强杀小红书
//   打开别人图文笔记 → 长按图片 / 分享面板 → 点「保存图片」
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <unistd.h>

// 需要调试时改成 1
static const BOOL kXHSVerbose = NO;
#define XHSLog(fmt, ...) do { if (kXHSVerbose) NSLog(@"[XHSImageSave] " fmt, ##__VA_ARGS__); } while (0)

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
// 吞掉 setDisableSave:YES 等，始终当成允许保存
static void XHS_setBoolIgnored(id self, SEL _cmd, BOOL v) {
    (void)self; (void)_cmd; (void)v;
    XHSLog(@"ignore %s %d", sel_getName(_cmd), (int)v);
}
static void XHS_setIdForceNo(id self, SEL _cmd, id v) {
    (void)self; (void)_cmd; (void)v;
    // 若原 setter 期望 NSNumber，尽量不崩：不调原实现即可（字段保持默认/已有值）
    XHSLog(@"ignore id setter %s", sel_getName(_cmd));
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

static void XHSReplaceIdGetterYes(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    if (!t) return;
    if (t[0] == '@') {
        method_setImplementation(m, (IMP)XHS_retYesNumber);
        XHSLog(@"id %s -%s -> @YES", class_getName(cls), sel_getName(sel));
    } else if (t[0] == 'B' || t[0] == 'c') {
        method_setImplementation(m, (IMP)XHS_retYES);
        XHSLog(@"BOOL %s -%s -> YES", class_getName(cls), sel_getName(sel));
    }
}

static void XHSBlockBoolSetter(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    if (!t) return;
    // 常见: v24@0:8B16 或 v24@0:8c16
    method_setImplementation(m, (IMP)XHS_setBoolIgnored);
}

static void XHSBlockIdSetter(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, (IMP)XHS_setIdForceNo);
}

#pragma mark - Per-class patch

static void XHSPatchSaveFlagsOnClass(Class cls) {
    if (!cls) return;

    // 核心：禁止保存 → 永远允许
    XHSReplaceBoolGetter(cls, sel_registerName("disableSave"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("isDisableSave"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("forbidCopy"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("isForbidCopy"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("disableCopy"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("disableCopyAction"), NO);

    // 保存时尽量不强制水印（字段语义：disableWatermark=YES 表示关闭水印）
    XHSReplaceBoolGetter(cls, sel_registerName("disableWatermark"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("disableWatermarkWhenSavingAlbum"), YES);

    XHSBlockBoolSetter(cls, sel_registerName("setDisableSave:"));
    XHSBlockBoolSetter(cls, sel_registerName("setForbidCopy:"));
    XHSBlockBoolSetter(cls, sel_registerName("setDisableCopy:"));
    XHSBlockBoolSetter(cls, sel_registerName("setDisableCopyAction:"));

    // 分享面板「保存图片」开关（可能是 BOOL 或 NSNumber）
    XHSReplaceIdGetterYes(cls, sel_registerName("shareImageSaveEnable"));
    XHSBlockIdSetter(cls, sel_registerName("setShareImageSaveEnable:"));
    XHSBlockBoolSetter(cls, sel_registerName("setShareImageSaveEnable:"));

    const char *name = class_getName(cls);
    if (!name) return;

    // SaveProvider.enable / 负反馈面板保存入口
    if (strstr(name, "SaveProvider") ||
        strstr(name, "NegativeFeedback") ||
        strstr(name, "ImageSave") ||
        strstr(name, "SaveImage") ||
        strstr(name, "NoteSave") ||
        strstr(name, "MediaSave")) {
        XHSReplaceBoolGetter(cls, sel_registerName("enable"), YES);
        XHSReplaceBoolGetter(cls, sel_registerName("isEnable"), YES);
        XHSReplaceBoolGetter(cls, sel_registerName("isEnabled"), YES);
        XHSReplaceIdGetterYes(cls, sel_registerName("enable"));
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
           strstr(name, "SaveImageService") ||
           strstr(name, "ImageSaveService");
}

static void XHSScanAndPatch(void) {
    // 已知 ObjC 类优先
    XHSPatchSaveFlagsOnClass(objc_getClass("XYPHMediaSaveConfig"));

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
            class_getInstanceMethod(cls, sel_registerName("mediaSaveConfig"));
        if (byName || bySel) {
            XHSPatchSaveFlagsOnClass(cls);
        }
    }
    free(list);
    XHSLog(@"scan done classes=%u", n);
}

#pragma mark - KVC soft filter on XYPHMediaSaveConfig only

static void (*orig_setValue_forKey)(id, SEL, id, NSString *);
static void hook_setValue_forKey(id self, SEL _cmd, id value, NSString *key) {
    if ([key isEqualToString:@"disableSave"] ||
        [key isEqualToString:@"disable_save"] ||
        [key isEqualToString:@"forbidCopy"] ||
        [key isEqualToString:@"forbid_copy"]) {
        value = @NO;
    } else if ([key isEqualToString:@"shareImageSaveEnable"] ||
               [key isEqualToString:@"share_image_save_enable"]) {
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

static void XHSTryHookConfigKVC(void) {
    Class cls = objc_getClass("XYPHMediaSaveConfig");
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(setValue:forKey:));
    if (!m) return;
    // 只替换该类自己的实现；若与 NSObject 相同则用 class_addMethod 覆盖
    IMP old = method_getImplementation(m);
    if (!orig_setValue_forKey) {
        orig_setValue_forKey = (void *)old;
    }
    // 用 class_replaceMethod 保证子类/本类走我们的逻辑
    class_replaceMethod(cls, @selector(setValue:forKey:),
                        (IMP)hook_setValue_forKey,
                        method_getTypeEncoding(m));
    XHSLog(@"KVC hook on XYPHMediaSaveConfig");
}

#pragma mark - mediaSaveConfig 访问：拿到配置后立刻把 disableSave 打掉

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
        // 只 hook 一次全局 orig 即可（多类共用同一 hook 函数，orig 取第一个）
        IMP prev = method_getImplementation(m);
        if (!orig_mediaSaveConfig) orig_mediaSaveConfig = (void *)prev;
        method_setImplementation(m, (IMP)hook_mediaSaveConfig);
        XHSLog(@"hook -mediaSaveConfig on %s", class_getName(cls));
    }
    free(list);
}

#pragma mark - 目标进程判断

static BOOL XHSIsTarget(void) {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid isEqualToString:@"com.xingin.discover"]) return YES;
    NSString *exe = [[NSBundle mainBundle].executablePath lastPathComponent] ?: @"";
    if ([exe isEqualToString:@"discover"]) return YES;
    // 空 bid 的极早构造阶段：先装 hook，无害
    if (bid.length == 0) return YES;
    return NO;
}

#pragma mark - Constructor

__attribute__((constructor))
static void XHSImageSaveInit(void) {
    @autoreleasepool {
        if (!XHSIsTarget()) return;
        XHSLog(@"loaded pid=%d bid=%@", getpid(), [NSBundle mainBundle].bundleIdentifier);

        XHSScanAndPatch();
        XHSTryHookConfigKVC();
        XHSHookMediaSaveConfigAccessors();

        // Swift / 懒加载模块稍晚再补两刀（无 UI、无 toast）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSScanAndPatch();
            XHSTryHookConfigKVC();
            XHSHookMediaSaveConfigAccessors();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSScanAndPatch();
            XHSHookMediaSaveConfigAccessors();
        });
    }
}
