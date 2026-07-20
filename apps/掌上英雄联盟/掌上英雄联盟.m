#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#ifndef QTL_NOADS_DEBUG
#define QTL_NOADS_DEBUG 0
#endif

#if QTL_NOADS_DEBUG
#define QTLLog(format, ...) NSLog(@"[QTLNoAds] " format, ##__VA_ARGS__)
#else
#define QTLLog(format, ...) do { } while (0)
#endif

typedef struct {
    __unsafe_unretained Class cls;
    IMP original;
} QTLViewHook;

static QTLViewHook gViewHooks[16];
static NSUInteger gViewHookCount = 0;
static BOOL gInstallScheduled = NO;

static void QTLAdViewDidMoveToWindow(UIView *self, SEL command);

static void QTLInvokeCompletion(void (^completion)(void)) {
    if (!completion) {
        return;
    }

    if ([NSThread isMainThread]) {
        completion();
    } else {
        dispatch_async(dispatch_get_main_queue(), completion);
    }
}

static void QTLNoop(id self, SEL command) {
    (void)self;
    (void)command;
}

static void QTLNoop1(id self, SEL command, id argument) {
    (void)self;
    (void)command;
    (void)argument;
}

static void QTLNoop2(id self, SEL command, id first, id second) {
    (void)self;
    (void)command;
    (void)first;
    (void)second;
}

static void QTLNoopInteger(id self, SEL command, NSInteger value) {
    (void)self;
    (void)command;
    (void)value;
}

static BOOL QTLReturnNo(id self, SEL command) {
    (void)self;
    (void)command;
    return NO;
}

static BOOL QTLReturnNo1(id self, SEL command, id argument) {
    (void)self;
    (void)command;
    (void)argument;
    return NO;
}

static BOOL QTLReturnNo3(id self, SEL command, id first, id second, id third) {
    (void)self;
    (void)command;
    (void)first;
    (void)second;
    (void)third;
    return NO;
}

static CGFloat QTLReturnZeroHeight(id self, SEL command) {
    (void)self;
    (void)command;
    return 0.0;
}

static CGFloat QTLReturnZeroHeight1(id self, SEL command, id argument) {
    (void)self;
    (void)command;
    (void)argument;
    return 0.0;
}

static void QTLHideView(UIView *view) {
    if (![view isKindOfClass:[UIView class]]) {
        return;
    }

    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;

    CGRect frame = view.frame;
    if (frame.size.height != 0.0) {
        frame.size.height = 0.0;
        view.frame = frame;
    }
}

static IMP QTLOriginalViewImplementation(id object) {
    Class current = object_getClass(object);
    while (current) {
        for (NSUInteger index = 0; index < gViewHookCount; index++) {
            if (gViewHooks[index].cls == current) {
                return gViewHooks[index].original;
            }
        }
        current = class_getSuperclass(current);
    }
    return NULL;
}

static IMP QTLStoredOriginalForClass(Class cls) {
    while (cls) {
        for (NSUInteger index = 0; index < gViewHookCount; index++) {
            if (gViewHooks[index].cls == cls &&
                gViewHooks[index].original != (IMP)QTLAdViewDidMoveToWindow) {
                return gViewHooks[index].original;
            }
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void QTLAdViewDidMoveToWindow(UIView *self, SEL command) {
    IMP original = QTLOriginalViewImplementation(self);
    if (original && original != (IMP)QTLAdViewDidMoveToWindow) {
        ((void (*)(id, SEL))original)(self, command);
    }
    QTLHideView(self);
}

static void QTLHideSelf(id self, SEL command) {
    (void)command;
    QTLHideView((UIView *)self);
}

static void QTLHideSelf1(id self, SEL command, id argument) {
    (void)command;
    (void)argument;
    QTLHideView((UIView *)self);
}

static void QTLHideSelf3(id self, SEL command, id first, id second, id third) {
    (void)command;
    (void)first;
    (void)second;
    (void)third;
    QTLHideView((UIView *)self);
}

static id QTLHideSelfAndReturnNil1(id self, SEL command, id argument) {
    (void)command;
    (void)argument;
    QTLHideView((UIView *)self);
    return nil;
}

static BOOL QTLHookMethod(Class cls, SEL selector, IMP replacement) {
    if (!cls || !selector || !replacement) {
        return NO;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return NO;
    }

    IMP current = class_getMethodImplementation(cls, selector);
    if (current == replacement) {
        return YES;
    }

    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, types)) {
        return YES;
    }

    method = class_getInstanceMethod(cls, selector);
    method_setImplementation(method, replacement);
    return YES;
}

static BOOL QTLHookInstanceMethod(const char *className, const char *selectorName, IMP replacement) {
    Class cls = objc_getClass(className);
    BOOL hooked = QTLHookMethod(cls, sel_registerName(selectorName), replacement);
    if (hooked) {
        QTLLog(@"hooked -[%s %s]", className, selectorName);
    }
    return hooked;
}

static BOOL QTLHookClassMethod(const char *className, const char *selectorName, IMP replacement) {
    Class cls = objc_getClass(className);
    Class metaClass = cls ? object_getClass(cls) : Nil;
    BOOL hooked = QTLHookMethod(metaClass, sel_registerName(selectorName), replacement);
    if (hooked) {
        QTLLog(@"hooked +[%s %s]", className, selectorName);
    }
    return hooked;
}

static void QTLHookAdViewClass(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls || ![cls isSubclassOfClass:[UIView class]]) {
        return;
    }

    for (NSUInteger index = 0; index < gViewHookCount; index++) {
        if (gViewHooks[index].cls == cls) {
            return;
        }
    }
    if (gViewHookCount >= sizeof(gViewHooks) / sizeof(gViewHooks[0])) {
        return;
    }

    SEL selector = @selector(didMoveToWindow);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return;
    }

    IMP original = class_getMethodImplementation(cls, selector);
    if (original == (IMP)QTLAdViewDidMoveToWindow) {
        original = QTLStoredOriginalForClass(class_getSuperclass(cls));
    }
    gViewHooks[gViewHookCount++] = (QTLViewHook){ cls, original };
    QTLHookMethod(cls, selector, (IMP)QTLAdViewDidMoveToWindow);
    QTLLog(@"installed view collapse for %s", className);
}

static void QTLStartWithoutSplash(id self,
                                  SEL command,
                                  id splashInfo,
                                  UIWindow *window,
                                  void (^dismissCallback)(void)) {
    (void)self;
    (void)command;
    (void)splashInfo;
    (void)window;
    QTLInvokeCompletion(dismissCallback);
}

static void QTLCompleteStoredSplashCallback(id self, SEL command) {
    (void)command;
    SEL getter = sel_registerName("dismissCallback");
    SEL setter = sel_registerName("setDismissCallback:");
    if (![self respondsToSelector:getter]) {
        return;
    }

    id value = ((id (*)(id, SEL))objc_msgSend)(self, getter);
    if ([self respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(self, setter, nil);
    }
    QTLInvokeCompletion((void (^)(void))value);
}

static void QTLFinishSplashManager(id self, SEL command) {
    (void)command;
    SEL finishedSetter = sel_registerName("setIsSplashFinished:");
    if ([self respondsToSelector:finishedSetter]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(self, finishedSetter, YES);
    }

    SEL removeSplash = sel_registerName("removeSplash");
    SEL remove = sel_registerName("remove");
    if ([self respondsToSelector:removeSplash]) {
        ((void (*)(id, SEL))objc_msgSend)(self, removeSplash);
    } else if ([self respondsToSelector:remove]) {
        ((void (*)(id, SEL))objc_msgSend)(self, remove);
    }
}

static void QTLFinishSplashManager1(id self, SEL command, id argument) {
    (void)argument;
    QTLFinishSplashManager(self, command);
}

static void QTLInstallHooks(void) {
    // App-owned launch ad orchestration. The entry callback must still run.
    QTLHookInstanceMethod("ADServiceManager", "startWithSplashInfo:window:dismissCallback:",
                          (IMP)QTLStartWithoutSplash);
    QTLHookInstanceMethod("ADServiceManager", "loadAdAndShowSplashAtColdLaunch",
                          (IMP)QTLCompleteStoredSplashCallback);
    QTLHookInstanceMethod("ADServiceManager", "loadAdAndShowSplashAtHotLaunch",
                          (IMP)QTLCompleteStoredSplashCallback);
    QTLHookInstanceMethod("ADServiceManager", "loadAdAndShowSplashAtHotLaunchIfNeeded",
                          (IMP)QTLCompleteStoredSplashCallback);
    QTLHookInstanceMethod("ADServiceManager", "preloadAdDataAtColdLaunch", (IMP)QTLNoop);
    QTLHookInstanceMethod("ADServiceManager", "preloadAdDataAtHotLaunch", (IMP)QTLNoop);
    QTLHookInstanceMethod("ADServiceManager", "showSplashAtColdLaunchWithWindow",
                          (IMP)QTLCompleteStoredSplashCallback);
    QTLHookInstanceMethod("ADServiceManager", "showSplashView",
                          (IMP)QTLCompleteStoredSplashCallback);

    QTLHookInstanceMethod("SplashViewManager", "splashEnterForeground", (IMP)QTLFinishSplashManager);
    QTLHookInstanceMethod("SplashViewManager", "showSplashInfoInView:",
                          (IMP)QTLFinishSplashManager1);
    QTLHookInstanceMethod("SplashViewManager", "setupImageAdForConfiguration:",
                          (IMP)QTLFinishSplashManager1);
    QTLHookInstanceMethod("SplashViewManager", "setupVideoAdForConfiguration:",
                          (IMP)QTLFinishSplashManager1);
    QTLHookInstanceMethod("SplashViewManager", "setupLaunchAd", (IMP)QTLFinishSplashManager);
    QTLHookInstanceMethod("SplashViewManager", "startSkipDispathTimer", (IMP)QTLNoop);
    QTLHookClassMethod("SplashViewManager", "enableAMSAdSplash:", (IMP)QTLReturnNo1);

    // GDT/AMS non-rewarded inventory.
    QTLHookInstanceMethod("GDTSplashAd", "loadAdAndShowSplashWithCustomUIModel:", (IMP)QTLNoop1);
    QTLHookInstanceMethod("GDTSplashAd", "preLoadSplashOrder:", (IMP)QTLNoop1);
    QTLHookInstanceMethod("GDTSplashAd", "showSplashWithOrder:withCustomUI:", (IMP)QTLNoop2);
    QTLHookInstanceMethod("GDTSplashAd", "showSplashWithOrder:withCustomUI:inContainerView:",
                          (IMP)QTLReturnNo3);

    QTLHookInstanceMethod("GDTUnifiedNativeAd", "loadAd", (IMP)QTLNoop);
    QTLHookInstanceMethod("GDTUnifiedNativeAd", "loadAdWithAdCount:", (IMP)QTLNoopInteger);
    QTLHookInstanceMethod("GDTUnifiedBannerView", "loadAdAndShow", (IMP)QTLHideSelf);
    QTLHookInstanceMethod("GDTUnifiedBannerView", "fetchAdAndShow", (IMP)QTLHideSelf);
    QTLHookInstanceMethod("GDTUnifiedInterstitialAd", "loadAd", (IMP)QTLNoop);
    QTLHookInstanceMethod("GDTUnifiedInterstitialAd", "loadFullScreenAd", (IMP)QTLNoop);
    QTLHookInstanceMethod("GDTUnifiedInterstitialAd", "presentAdFromRootViewController:",
                          (IMP)QTLNoop1);
    QTLHookInstanceMethod("GDTUnifiedInterstitialAd", "presentFullScreenAdFromRootViewController:",
                          (IMP)QTLNoop1);
    QTLHookInstanceMethod("GDTUnifiedInterstitialAd", "isAdValid", (IMP)QTLReturnNo);

    QTLHookInstanceMethod("AMSCustomBannerRequest", "requestWithCount:", (IMP)QTLNoopInteger);
    QTLHookInstanceMethod("AMSCustomBannerView", "setupWithUnifiedNativeAdDataObject:delegate:vc:",
                          (IMP)QTLHideSelf3);
    QTLHookInstanceMethod("AMSCustomBannerView", "setupWithUnifiedNativeAdObject:",
                          (IMP)QTLHideSelf1);

    // App-specific ad containers and height providers.
    QTLHookClassMethod("QTLVideoDetailAdCell", "getHeight", (IMP)QTLReturnZeroHeight);
    QTLHookInstanceMethod("QTLVideoDetailAdCell", "updateView:", (IMP)QTLHideSelf1);
    QTLHookClassMethod("QTLVideoDetailAdView", "getHeight:", (IMP)QTLReturnZeroHeight1);
    QTLHookInstanceMethod("QTLVideoDetailAdView", "updateView:", (IMP)QTLHideSelf1);
    QTLHookInstanceMethod("DWStreamAdView", "loadPageWithBundleId:adInfo:delegate:",
                          (IMP)QTLHideSelf3);
    QTLHookInstanceMethod("WGXNewsFloatAdView", "createLoadDataRequest:",
                          (IMP)QTLHideSelfAndReturnNil1);
    QTLHookInstanceMethod("WGXNewsFloatAdView", "loadAndShowAniImageView:",
                          (IMP)QTLHideSelf1);
    QTLHookInstanceMethod("WGXNewsFloatAdView", "reportAdExpoIfNeeded", (IMP)QTLNoop);

    const char *viewClasses[] = {
        "AMSCustomBannerView",
        "GDTUnifiedBannerView",
        "QTLVideoDetailAdCell",
        "QTLVideoDetailAdView",
        "DWStreamAdView",
        "WGXNewsFloatAdView",
        "XHLaunchAdImageView",
        "XHLaunchAdVideoView"
    };
    for (NSUInteger index = 0; index < sizeof(viewClasses) / sizeof(viewClasses[0]); index++) {
        QTLHookAdViewClass(viewClasses[index]);
    }
}

static void QTLScheduleHookInstallation(void) {
    if (gInstallScheduled) {
        return;
    }
    gInstallScheduled = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        QTLInstallHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            QTLInstallHooks();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            QTLInstallHooks();
        });
    });
}

__attribute__((constructor, used))
static void QTLNoAdsInitialize(void) {
    @autoreleasepool {
        QTLScheduleHookInstallation();
    }
}
