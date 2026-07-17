//
// Volunteer.dylib — 志愿汇 / Volunteer 去广告 (TrollFools)
// Bundle 可执行名: Volunteer | 分析版本: 5.8.4
//
// 广告栈:
//   业务: AdvertisementManager / TopOn*Manager / CJAD* / AdWare / RCAd / HomeSuspension / Mine*
//   开屏: XHLaunchAd + TopOnSplash + BeiZi/GDT/CSJ/MS/Oct/YF/LingYe
//   聚合: TopOn / AnyThink (AT*) + GroMore(ABU) + YFAd
//
// 性能: 白名单定点 hook，不全量扫类，不 hook UIView 根类，默认无日志。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static const BOOL kVerbose = NO;
// YES = 保留激励视频 load（若 App 内有看广告领奖励可开）
static const BOOL kKeepReward = NO;

#define VLLog(fmt, ...) do { if (kVerbose) NSLog(@"[Volunteer] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - Stubs

static void stub_v0(id s, SEL c) {}
static void stub_v1(id s, SEL c, id a) {}
static void stub_v2(id s, SEL c, id a, id b) {}
static void stub_v3(id s, SEL c, id a, id b, id d) {}
static void stub_v4(id s, SEL c, id a, id b, id d, id e) {}
static void stub_v5(id s, SEL c, id a, id b, id d, id e, id f) {}
static BOOL stub_NO(id s, SEL c) { return NO; }
static id   stub_nil0(id s, SEL c) { return nil; }
static id   stub_nil1(id s, SEL c, id a) { return nil; }
static id   stub_nil2(id s, SEL c, id a, id b) { return nil; }

static IMP stubForMethod(Method method) {
    const char *enc = method_getTypeEncoding(method);
    if (!enc) return NULL;
    unsigned argc = method_getNumberOfArguments(method);
    switch (enc[0]) {
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
    SEL sel = sel_registerName(selectorName);
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP rep = stubForMethod(m);
    if (!rep) return NO;
    if (method_getImplementation(m) != rep) method_setImplementation(m, rep);
    return YES;
}

static BOOL selectorIsAdControl(const char *name) {
    if (!name) return NO;
    if (kKeepReward && (strstr(name, "Reward") || strstr(name, "reward"))) {
        // 仅放过 load，仍拦 show
        if (strstr(name, "load") || strstr(name, "Load") || strstr(name, "request") || strstr(name, "Request")) {
            return NO;
        }
    }
    return
        strstr(name, "loadAd") || strstr(name, "loadAD") || strstr(name, "LoadAd") ||
        strstr(name, "showAd") || strstr(name, "showAD") || strstr(name, "ShowAd") ||
        strstr(name, "requestAd") || strstr(name, "fetchAd") ||
        strstr(name, "loadSplash") || strstr(name, "showSplash") ||
        strstr(name, "loadInterstitial") || strstr(name, "showInterstitial") ||
        strstr(name, "loadReward") || strstr(name, "showReward") ||
        strstr(name, "loadBanner") || strstr(name, "showBanner") ||
        strstr(name, "loadNative") || strstr(name, "showNative") ||
        strstr(name, "loadADWith") || strstr(name, "loadAdWith") ||
        strstr(name, "cjLoadAnShow") ||
        strstr(name, "showLaunch") || strstr(name, "initAds") ||
        strstr(name, "showToWindowSplash") ||
        strstr(name, "showSplashAdFromWindow") ||
        strstr(name, "showFromRootViewController") ||
        strstr(name, "setupSDKWithAppId") ||
        strstr(name, "preInitWithAdn") ||
        strcmp(name, "isReady") == 0 || strcmp(name, "isAdValid") == 0 ||
        strcmp(name, "canShowAd") == 0 || strcmp(name, "canShowAdByInstallAppTime") == 0 ||
        strcmp(name, "loadAD") == 0;
}

static int hookAdControlsOnClass(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) return 0;
    int hooked = 0;

    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned i = 0; i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (!selectorIsAdControl(name)) continue;
        IMP rep = stubForMethod(methods[i]);
        if (rep) {
            method_setImplementation(methods[i], rep);
            hooked++;
        }
    }
    free(methods);

    Class meta = object_getClass((id)cls);
    count = 0;
    methods = meta ? class_copyMethodList(meta, &count) : NULL;
    for (unsigned i = 0; methods && i < count; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        if (!selectorIsAdControl(name)) continue;
        IMP rep = stubForMethod(methods[i]);
        if (rep) {
            method_setImplementation(methods[i], rep);
            hooked++;
        }
    }
    free(methods);
    return hooked;
}

#pragma mark - Known classes

static const char *kAdControlClasses[] = {
    // 业务层
    "AdvertisementManager",
    "TopOnSplashManager",
    "TopOnInterstitialManager",
    "TopOnNativeManager",
    "TopOnRewardVideoManager",
    "TopOnSplashVC",
    "CJADManager",
    "CJSplashView",
    "CJSplashAd",
    "CJSplashAdLoader",
    "CJInterstitialView",
    "CJInterstitialAd",
    "CJInterstitialController",
    "CJNaiveADRequest",
    "CJBaseSceneController",
    "AdWareViewModel",
    "RCAdManager",
    "HomeSuspensionAdView",
    "MineBannerView",
    "MineNativeAdView",
    "PBAdvertisementVC",

    // XHLaunchAd 开屏
    "XHLaunchAd",
    "XHLaunchAdController",
    "XHLaunchAdDownloader",
    "XHLaunchAdImageManager",

    // TopOn / AnyThink
    "ATAPI",
    "ATAdManager",
    "ATSplash",
    "ATRewardedVideo",
    "ATInterstitial",
    "ATBanner",
    "ATNativeADView",
    "ATNativeADManager",

    // YFAd 聚合
    "YFAdSDKManager",
    "YFAdSupplierManager",
    "YFSplashAdapter",
    "YFInterstitialAdapter",
    "YFRewardVideoAdapter",
    "YFBannerAdapter",
    "YFNativeExpressAdapter",
    "YFFullScreenVideoAdapter",

    // GroMore / ABU
    "ABUAdSDKManager",
    "ABUSplashAd",
    "ABUBannerAd",
    "ABUInterstitialAd",
    "ABUInterstitialProAd",
    "ABURewardedVideoAd",
    "ABUNativeAdView",

    // GDT 优量汇
    "GDTSDKConfig",
    "GDTSplashAd",
    "GDTRewardVideoAd",
    "GDTUnifiedBannerView",
    "GDTUnifiedInterstitialAd",
    "GDTUnifiedNativeAd",

    // 穿山甲 / BU
    "BUAdSDKManager",
    "BUSplashAd",
    "BUNativeExpressBannerView",
    "BUNativeExpressInterstitialAd",
    "BUNativeExpressRewardedVideoAd",
    "BUNativeAdsManager",
    "BUNativeAd",

    // 倍孜 / 美数 / 章鱼 / 灵烨 / 快手 / 京东广告
    "BeiZiSDK",
    "BeiZiSplash",
    "BeiZiSplashManager",
    "BeiZiInterstitial",
    "BeiZiInterstitialManager",
    "BeiZiRewardedVideo",
    "BeiZiRewardedVideoManager",
    "BeiZiBannerAdManager",
    "BeiZiNativeExpressAdManager",
    "MSAdSDK",
    "MSSplashAd",
    "MSSplashAdLoaderManager",
    "MSBannerAdView",
    "MSBannerAdLoaderManager",
    "MSInterstitialAd",
    "MSInterstitialAdLoaderManager",
    "MSRewardVideoAd",
    "MSRewardVideoAdLoaderManager",
    "MSNativeAd",
    "MSNativeAdLoaderManager",
    "OctAdManager",
    "OctAdBanner",
    "OctAdIntersitital",
    "OctAdFullScreenVedio",
    "OctAdDrawVedio",
    "OctAdNative",
    "LingYeSplashAd",
    "LingYeNativeExpressBannerAd",
    "LingYeNativeExpressInterstitialAd",
    "LingYeNativeExpressRewardVideoAd",
    "LingYeNativeExpressAdManager",
    "KSSplashAdView",
    "KSInterstitialAd",
    "KSRewardedVideoAd",
    "JADSplashView",
    "AMPSSplashAd",
    "AMPSInterstitialAd",
    "AMPSRewardedVideoAd",
    "AMPSUnifiedNativeAd",
    NULL
};

static int applyExactHooks(void) {
    int n = 0;
    const struct { const char *cls; const char *sel; BOOL meta; } exact[] = {
        // 启动开屏主链路
        { "AdvertisementManager", "showLaunchWithWindow:success:failure:complete:", NO },
        { "AdvertisementManager", "initAds", NO },
        { "AdvertisementManager", "canShowAdByInstallAppTime", NO },
        { "AdvertisementManager", "showLaunchAdSuccess", NO },
        { "AdvertisementManager", "showLaunchAdFailure", NO },
        { "AdvertisementManager", "showLaunchAdComplete", NO },

        { "XHLaunchAd", "setImageAdConfiguration:", YES },
        { "XHLaunchAd", "setVideoAdConfiguration:", YES },
        { "XHLaunchAd", "removeAndAnimated:", YES },
        { "XHLaunchAd", "downLoadImageAndCacheWithURLArray:", YES },
        { "XHLaunchAd", "downLoadVideoAndCacheWithURLArray:", YES },

        { "TopOnSplashManager", "loadAD", NO },
        { "TopOnSplashManager", "loadADWithPlacementID:extra:delegate:", NO },
        { "TopOnSplashManager", "showAd", NO },
        { "TopOnSplashManager", "showSplashAd", NO },
        { "TopOnInterstitialManager", "loadInterstitialAd:resultCallback:", NO },
        { "TopOnInterstitialManager", "showAd:", NO },
        { "TopOnNativeManager", "loadAD", NO },
        { "TopOnNativeManager", "loadNativeAd", NO },
        { "TopOnRewardVideoManager", "loadRewardAd:", NO },
        { "TopOnRewardVideoManager", "showAd", NO },
        { "TopOnRewardVideoManager", "showRewardAd", NO },

        { "CJADManager", "configure", YES },
        { "CJADManager", "configure:completeHandle:", YES },
        { "CJADManager", "startConfig:", YES },
        { "CJSplashView", "showToWindowSplash:bottom:", NO },
        { "CJInterstitialView", "showController:", NO },
        { "CJNaiveADRequest", "showNativeAdWithRootViewController:adType:", NO },
        { "CJBaseSceneController", "loadInterstitialAd", NO },
        { "CJBaseSceneController", "loadNativeAd", NO },
        { "CJBaseSceneController", "loadRewardVideoAd", NO },

        { "AdWareViewModel", "showSplashAdFromWindow:baseInfo:", NO },
        { "AdWareViewModel", "showFromRootViewController:adType:", NO },
        { "AdWareViewModel", "setupMetaData:", NO },
        { "RCAdManager", "initAd", NO },

        { "HomeSuspensionAdView", "showAdInView:", NO },
        { "MineBannerView", "showAdWithVC:adList:", NO },
        { "MineNativeAdView", "showAdInView:", NO },
        { "HomeVC", "requestHomeSuspensionAd", NO },

        // 聚合 SDK 初始化
        { "YFAdSDKManager", "setupSDKWithAppId:config:", YES },
        { "YFAdSDKManager", "preInitWithAdn:", YES },
        { "ATAPI", "startWithAppID:appKey:", YES },
        { "ATAPI", "sharedInstance", YES },
        { "ATAdManager", "loadADWithPlacementID:extra:delegate:", NO },
        { "ABUAdSDKManager", "startWithSyncCompletionHandler:", YES },
        { "BUAdSDKManager", "startWithAsyncCompletionHandler:", YES },
        { "GDTSDKConfig", "registerAppId:", YES },

        { NULL, NULL, NO }
    };
    for (int i = 0; exact[i].cls; i++) {
        n += hookMethod(exact[i].cls, exact[i].sel, exact[i].meta) ? 1 : 0;
    }
    return n;
}

static int applyAdControlHooks(void) {
    int hooked = 0;
    for (int i = 0; kAdControlClasses[i]; i++) {
        hooked += hookAdControlsOnClass(kAdControlClasses[i]);
    }
    hooked += applyExactHooks();
    return hooked;
}

#pragma mark - Ad view hide

static const char *kAdViewClasses[] = {
    "HomeSuspensionAdView",
    "MineBannerView",
    "MineNativeAdView",
    "XHLaunchAdImageView",
    "XHLaunchAdVideoView",
    "XHLaunchAdButton",
    "CJSplashView",
    "CJInterstitialView",
    "TopOnSplashVC",
    "GDTUnifiedBannerView",
    "GDTUnifiedNativeAdView",
    "BUNativeExpressAdView",
    "BUNativeExpressBannerView",
    "BUSplashAdView",
    "CSJNativeExpressAdView",
    "BeiZiBannerAdView",
    "BeiZiBannerView",
    "BeiZiNativeExpressAdView",
    "BeiZiADView",
    "MSBannerAdView",
    "MSBannerView",
    "MSSplashScreenView",
    "MSNativeCustomAdView",
    "OctAdBanner",
    "LingYeFSplashAdView",
    "LingYeFNativeExpressAdView",
    "LingYeFNativeExpressBannerAdView",
    "LingYeFRewardAdView",
    "KSSplashAdView",
    "JADSplashView",
    "ABUNativeAdView",
    "ABUBannerAd",
    NULL
};

static void hideAdView(UIView *view) {
    view.hidden = YES;
    view.alpha = 0.0;
    view.userInteractionEnabled = NO;
    view.clipsToBounds = YES;
    CGRect f = view.frame;
    if (f.size.height > 0.5) {
        f.size.height = 0;
        view.frame = f;
    }
}

static void volunteerAdViewDidMove(UIView *self, SEL cmd) {
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
    const char *enc = method_getTypeEncoding(root);
    for (int i = 0; kAdViewClasses[i]; i++) {
        Class cls = objc_getClass(kAdViewClasses[i]);
        if (!cls || ![cls isSubclassOfClass:[UIView class]]) continue;
        if (!class_addMethod(cls, @selector(didMoveToWindow), (IMP)volunteerAdViewDidMove, enc)) {
            Method own = class_getInstanceMethod(cls, @selector(didMoveToWindow));
            if (own && method_getImplementation(own) != (IMP)volunteerAdViewDidMove) {
                method_setImplementation(own, (IMP)volunteerAdViewDidMove);
            }
        }
    }
}

#pragma mark - present 拦截

static void (*originalPresent)(id, SEL, id, BOOL, id);

static BOOL isAdViewControllerName(const char *name) {
    if (!name) return NO;
    if (strstr(name, "Splash") && (strstr(name, "Ad") || strstr(name, "TopOn") || strstr(name, "XHLaunch") || strstr(name, "BeiZi") || strstr(name, "MS") || strstr(name, "CJ") || strstr(name, "GDT") || strstr(name, "BU") || strstr(name, "KS") || strstr(name, "JAD") || strstr(name, "LingYe") || strstr(name, "Oct") || strstr(name, "ABU") || strstr(name, "YF"))) return YES;
    if (strstr(name, "Interstitial") && strstr(name, "Ad")) return YES;
    if (strstr(name, "Reward") && strstr(name, "Ad")) return YES;
    if (strstr(name, "XHLaunchAd")) return YES;
    if (strstr(name, "TopOnSplash")) return YES;
    if (strstr(name, "PBAdvertisement")) return YES;
    if (strstr(name, "Advertisement") && strstr(name, "VC")) return YES;
    return NO;
}

static void volunteerPresent(UIViewController *self, SEL cmd, UIViewController *vc, BOOL animated, id completion) {
    if (vc && isAdViewControllerName(class_getName(object_getClass(vc)))) {
        VLLog(@"blocked present %s", class_getName(object_getClass(vc)));
        if (completion) ((void (^)(void))completion)();
        return;
    }
    if (originalPresent) originalPresent(self, cmd, vc, animated, completion);
}

static void installPresentHook(void) {
    Method m = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (!m) return;
    originalPresent = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)volunteerPresent);
}

#pragma mark - Entry

static void applyHooks(const char *phase) {
    int count = applyAdControlHooks();
    installAdViewHooks();
    VLLog(@"%s hooks=%d", phase, count);
}

__attribute__((constructor))
static void VolunteerDylibInit(void) {
    @autoreleasepool {
        installPresentHook();
        applyHooks("constructor");

        dispatch_async(dispatch_get_main_queue(), ^{
            applyHooks("main");
        });

        // 聚合 SDK / 业务模块懒加载补一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            applyHooks("delayed");
        });
    }
}
