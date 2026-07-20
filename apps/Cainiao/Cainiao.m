//
// Cainiao4iPhone.dylib — 菜鸟去广告 (TrollFools)
// Bundle: com.cainiao.cnwireless | 分析版本: 8.11.119
//
// 纯 Objective-C runtime 定点 hook：不依赖 Substrate，不全量扫类，默认无日志。
// 覆盖：启动/回前台开屏、物流详情 Banner、搜索广告、推荐流广告。
// 激励广告默认保留，避免破坏领取奖励功能。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static const BOOL kVerbose = NO;
#define CNLog(fmt, ...) do { if (kVerbose) NSLog(@"[Cainiao4iPhone] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - Safe stubs

static void stub_v0(id self, SEL cmd) {}
static void stub_v1(id self, SEL cmd, id a) {}
static void stub_v2(id self, SEL cmd, id a, id b) {}
static void stub_v3(id self, SEL cmd, id a, id b, id c) {}
static void stub_v4(id self, SEL cmd, id a, id b, id c, id d) {}
static void stub_v5(id self, SEL cmd, id a, id b, id c, id d, id e) {}
static BOOL stub_NO(id self, SEL cmd) { return NO; }
static id stub_nil0(id self, SEL cmd) { return nil; }
static id stub_nil1(id self, SEL cmd, id a) { return nil; }
static id stub_nil2(id self, SEL cmd, id a, id b) { return nil; }

static IMP stubForMethod(Method method) {
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding) return NULL;
    unsigned argc = method_getNumberOfArguments(method);
    switch (encoding[0]) {
        case 'v':
            if (argc <= 2) return (IMP)stub_v0;
            if (argc == 3) return (IMP)stub_v1;
            if (argc == 4) return (IMP)stub_v2;
            if (argc == 5) return (IMP)stub_v3;
            if (argc == 6) return (IMP)stub_v4;
            return (IMP)stub_v5;
        case 'B':
        case 'c': return (IMP)stub_NO;
        case '@':
            if (argc <= 2) return (IMP)stub_nil0;
            if (argc == 3) return (IMP)stub_nil1;
            return (IMP)stub_nil2;
        default: return NULL;
    }
}

static BOOL hookMethod(const char *className, const char *selectorName, BOOL classMethod) {
    Class cls = objc_getClass(className);
    if (!cls) return NO;
    SEL selector = sel_registerName(selectorName);
    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    if (!method) return NO;
    IMP replacement = stubForMethod(method);
    if (!replacement) return NO;
    if (method_getImplementation(method) != replacement) {
        method_setImplementation(method, replacement);
    }
    return YES;
}

static BOOL selectorIsAdControl(const char *name) {
    if (!name) return NO;
    return
        strstr(name, "loadAd") || strstr(name, "loadAD") || strstr(name, "LoadAd") ||
        strstr(name, "showAd") || strstr(name, "showAD") || strstr(name, "ShowAd") ||
        strstr(name, "requestAd") || strstr(name, "fetchAd") ||
        strstr(name, "loadSplash") || strstr(name, "showSplash") ||
        strstr(name, "requestSplash") || strstr(name, "beginToShowSplash") ||
        strstr(name, "loadAndShowSplash") || strstr(name, "splashAdsRequest") ||
        strstr(name, "loadBannerAd") || strstr(name, "showBannerAd") ||
        strstr(name, "loadInterstitialAd") || strstr(name, "showInterstitialAd") ||
        strcmp(name, "isReady") == 0 || strcmp(name, "isAdValid") == 0 ||
        strcmp(name, "canShowAd") == 0 || strcmp(name, "shouldShowAd") == 0;
}

static int hookAdControlsOnClass(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) return 0;
    int hooked = 0;

    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        const char *name = sel_getName(selector);
        if (selectorIsAdControl(name)) {
            IMP replacement = stubForMethod(methods[i]);
            if (replacement) {
                method_setImplementation(methods[i], replacement);
                hooked++;
            }
        }
    }
    free(methods);

    Class meta = object_getClass((id)cls);
    count = 0;
    methods = meta ? class_copyMethodList(meta, &count) : NULL;
    for (unsigned i = 0; i < count; i++) {
        SEL selector = method_getName(methods[i]);
        const char *name = sel_getName(selector);
        if (selectorIsAdControl(name)) {
            IMP replacement = stubForMethod(methods[i]);
            if (replacement) {
                method_setImplementation(methods[i], replacement);
                hooked++;
            }
        }
    }
    free(methods);
    return hooked;
}

#pragma mark - Known Cainiao ad classes

static const char *kAdControlClasses[] = {
    // 菜鸟启动开屏主链路
    "CNLaunchSplashManager",
    "CNLaunchSplashInitialize",
    "CNLaunchSplashEnterForegroundTrigger",
    "CNLaunchSplashViewController",
    "CNGLaunchSplash",
    "CNGLaunchSplashDispatchCenter",
    "CNGLaunchSplashPrefetchAds",
    "CNGLaunchSplashRTBManager",
    "CNGLaunchSplashRTBPreloadManager",
    "CNGLaunchSplashRTBService",
    "CNGLaunchSplashAdsImageManager",
    "CNVideoSplashConfigManager",
    "CNVideoSplashContentDataManager",

    // 菜鸟三方开屏聚合
    "CNGBaseThirdPartySDKSplashAdsManager",
    "CNGCSJSplashAdsManager",
    "CNGMSSplashAdsManager",
    "CNGUbiXSplashAdsManager",
    "CNGYLHSplashAdsManager",
    "CNGThirdPartySDKBaseSplashAd",
    "CNGCSJBaseSplashAd",
    "CNGCSJDirectSplashAd",
    "CNGCSJS2SBiddingSplashAd",
    "CNGMSS2SBiddingSplashAd",
    "CNGUbiXS2SBiddingSplashAd",
    "CNGYLHSplashAd",

    // SDK 直接入口
    "CSJSplashAd",
    "CSJSplashAdLoader",
    "BUSplashAd",
    "GDTSplashAd",
    "MSSplashAd",
    "MSSplashAdLoaderManager",
    "UBiXSplashAd",
    "UBiXSplashAdManager",
    "BaiduMobAdSplash",
    "KSSplashAdView",
    "JADSplashView",

    // Banner / 搜索 / 推荐流
    "CNHybridTTBannerAdImplementation",
    "CNLogisticsDetailBannerAdsUTManager",
    "CNLogisticsDetailBannerChannelAdsView",
    "CNLogisticsDetailBannerYLHAdView",
    "CNLogisticsDetailBannerOneTwoImageAdsView",
    "CNLogisticsDetailBannerThreeImageAdsView",
    "CNGSearchAlertAdView",
    "CNAdRecommendYLHFeedsAdView",
    "UBiXBannerAdHandler",
    "UBiXBannerAdManager",
    "UBiXBannerAdView",
    "MSBannerAdLoaderManager",
    "MSBannerAdView",

    // Swift 类
    "_TtC10CNB4iPhone9CNBSplash",
    "_TtC14Cainiao4iPhone20CNGSearchAlertAdView",
    "_TtC14Cainiao4iPhone21CNLaunchSplashTwister",
    NULL
};

static int applyAdControlHooks(void) {
    int hooked = 0;
    for (int i = 0; kAdControlClasses[i]; i++) {
        hooked += hookAdControlsOnClass(kAdControlClasses[i]);
    }

    // 主链路中不一定含 “Ad” 的精确方法
    const struct { const char *cls; const char *sel; BOOL meta; } exact[] = {
        { "CNLaunchSplashManager", "showAndDisappearAutomatically", NO },
        { "CNLaunchSplashManager", "showTopViewIconIfNeededWithCurrentConfigEntry", NO },
        { "CNLaunchSplashViewController", "viewDidLoad", NO },
        { "CNGLaunchSplashDispatchCenter", "requestSplashAdsWithIsAppFirstLaunch:", NO },
        { "CNGCSJSplashAdsManager", "requestCSJSplashAds", NO },
        { "CNHybridTTBannerAdImplementation", "showBUBannerViewInController", NO },
        { "CNHybridTTBannerAdImplementation", "showBUBannerViewInController:", NO },
        { NULL, NULL, NO }
    };
    for (int i = 0; exact[i].cls; i++) {
        hooked += hookMethod(exact[i].cls, exact[i].sel, exact[i].meta) ? 1 : 0;
    }
    return hooked;
}

#pragma mark - Targeted ad view hiding

static const char *kAdViewClasses[] = {
    "CNGLaunchSplashView",
    "CNGLaunchSplashImageView",
    "CNGLaunchSplashVideoView",
    "CNGLaunchSplashPlaceholderView",
    "CNLaunchSplashViewController",
    "CNGSearchAlertAdView",
    "_TtC14Cainiao4iPhone20CNGSearchAlertAdView",
    "CNAdRecommendYLHFeedsAdView",
    "CNLogisticsDetailBannerChannelAdsView",
    "CNLogisticsDetailBannerYLHAdView",
    "CNLogisticsDetailBannerOneTwoImageAdsView",
    "CNLogisticsDetailBannerThreeImageAdsView",
    "UBiXBannerAdView",
    "UBiXBannerAdContentView",
    "UBiXSplashAdView",
    "UBiXSplashAdContentView",
    "BUSplashAdView",
    "MSBannerAdView",
    "MSSplashAdViewController",
    "CSJFullScreenInterstitialAdView",
    NULL
};

static void hideAdView(UIView *view) {
    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    view.clipsToBounds = YES;
    CGRect frame = view.frame;
    if (frame.size.height > 0.5) {
        frame.size.height = 0;
        view.frame = frame;
    }
}

static void cainiaoAdViewDidMove(UIView *self, SEL cmd) {
    // 调 UIView 根实现；不 hook 全体 UIView
    static void (*rootDidMove)(id, SEL);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method root = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
        rootDidMove = root ? (void *)method_getImplementation(root) : NULL;
    });
    if (rootDidMove) rootDidMove(self, cmd);
    if (self.window) hideAdView(self);
}

static void installAdViewHooks(void) {
    Method root = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
    if (!root) return;
    const char *encoding = method_getTypeEncoding(root);

    for (int i = 0; kAdViewClasses[i]; i++) {
        Class cls = objc_getClass(kAdViewClasses[i]);
        if (!cls || ![cls isSubclassOfClass:[UIView class]]) continue;
        if (!class_addMethod(cls, @selector(didMoveToWindow), (IMP)cainiaoAdViewDidMove, encoding)) {
            Method own = class_getInstanceMethod(cls, @selector(didMoveToWindow));
            if (own && method_getImplementation(own) != (IMP)cainiaoAdViewDidMove) {
                method_setImplementation(own, (IMP)cainiaoAdViewDidMove);
            }
        }
    }
}

#pragma mark - Block presentation of ad VCs only

static void (*originalPresent)(id, SEL, id, BOOL, id);

static BOOL isAdViewControllerName(const char *name) {
    if (!name) return NO;
    return
        strstr(name, "LaunchSplash") || strstr(name, "SplashAd") ||
        strstr(name, "MSSplash") || strstr(name, "UBiXSplash") ||
        strstr(name, "CSJSplash") || strstr(name, "BUSplash") ||
        strstr(name, "GDTSplash") || strstr(name, "KSSplash") ||
        strstr(name, "SearchAlertAd") ||
        (strstr(name, "Interstitial") && strstr(name, "Ad"));
}

static void cainiaoPresent(UIViewController *self, SEL cmd, UIViewController *vc, BOOL animated, id completion) {
    if (vc && isAdViewControllerName(class_getName(object_getClass(vc)))) {
        CNLog(@"blocked %@", NSStringFromClass(object_getClass(vc)));
        if (completion) ((void (^)(void))completion)();
        return;
    }
    if (originalPresent) originalPresent(self, cmd, vc, animated, completion);
}

static void installPresentHook(void) {
    Method method = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (!method) return;
    originalPresent = (void *)method_getImplementation(method);
    method_setImplementation(method, (IMP)cainiaoPresent);
}

#pragma mark - Entry

static void applyHooks(const char *phase) {
    int count = applyAdControlHooks();
    installAdViewHooks();
    CNLog(@"%s hooks=%d", phase, count);
}

__attribute__((constructor))
static void Cainiao4iPhoneInit(void) {
    @autoreleasepool {
        installPresentHook();
        applyHooks("constructor");

        // +load / Swift 注册后补一次；只遍历白名单类，不扫全局
        dispatch_async(dispatch_get_main_queue(), ^{
            applyHooks("main");
        });

        // 阿里模块可能懒加载：后台再补一次，不阻塞首屏
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            applyHooks("delayed");
        });
    }
}
