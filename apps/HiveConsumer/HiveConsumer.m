//
// HiveConsumer.dylib — 丰巢去广告 (TrollFools)
// Bundle: com.fcbox.hiveconsumer | 分析版本: 6.32.0
//
// v3 针对:
//   - 久置后回前台 / 冷启动热开屏 (WindMill / UBiX / ToBid / Sigmob)
//   - 闪约 1s 后 openURL / 商店页外跳
//
// 性能原则:
//   - 不扫全进程类表
//   - 不 hook UIView 根类
//   - 默认关闭日志
//   - 白名单 + 回前台再补 hook
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

#pragma mark - Config

static const BOOL kFakeReward = NO;
static const BOOL kVerbose    = NO;

#define HCLog(fmt, ...) do { \
    if (kVerbose) NSLog(@"[HiveConsumer] " fmt, ##__VA_ARGS__); \
} while (0)

#pragma mark - Silent stubs

static void stub_v0(id s, SEL c) {}
static void stub_v1(id s, SEL c, id a) {}
static void stub_v2(id s, SEL c, id a, id b) {}
static void stub_v3(id s, SEL c, id a, id b, id d) {}
static void stub_v4(id s, SEL c, id a, id b, id d, id e) {}
static void stub_v5(id s, SEL c, id a, id b, id d, id e, id f) {}
static BOOL stub_NO(id s, SEL c) { return NO; }
static id   stub_nil(id s, SEL c) { return nil; }
static id   stub_nil1(id s, SEL c, id a) { return nil; }
static id   stub_nil2(id s, SEL c, id a, id b) { return nil; }

static IMP stubForEncoding(const char *type, unsigned argc) {
    if (!type) return NULL;
    char r = type[0];
    if (r == 'v') {
        if (argc <= 2) return (IMP)stub_v0;
        if (argc == 3) return (IMP)stub_v1;
        if (argc == 4) return (IMP)stub_v2;
        if (argc == 5) return (IMP)stub_v3;
        if (argc == 6) return (IMP)stub_v4;
        return (IMP)stub_v5;
    }
    if (r == 'B' || r == 'c') return (IMP)stub_NO;
    if (r == '@') {
        if (argc <= 2) return (IMP)stub_nil;
        if (argc == 3) return (IMP)stub_nil1;
        return (IMP)stub_nil2;
    }
    return NULL;
}

static BOOL replaceMethod(Class cls, SEL sel, BOOL meta) {
    if (!cls || !sel) return NO;
    Method m = meta ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    unsigned n = method_getNumberOfArguments(m);
    IMP imp = stubForEncoding(enc, n);
    if (!imp) return NO;
    if (method_getImplementation(m) != imp) method_setImplementation(m, imp);
    return YES;
}

static int hookSel(const char *cname, const char *sname, BOOL meta) {
    Class cls = objc_getClass(cname);
    if (!cls) return 0;
    return replaceMethod(cls, sel_registerName(sname), meta) ? 1 : 0;
}

static BOOL selectorLooksLikeAdControl(const char *sn) {
    if (!sn) return NO;
    return
        strstr(sn, "loadAd") || strstr(sn, "LoadAd") || strstr(sn, "loadAD") ||
        strstr(sn, "showAd") || strstr(sn, "ShowAd") || strstr(sn, "showAD") ||
        strstr(sn, "showSplash") || strstr(sn, "loadSplash") ||
        strstr(sn, "loadAndShowSplash") || strstr(sn, "beginToShowSplash") ||
        strstr(sn, "autoShowAd") || strstr(sn, "showAdInWindow") ||
        strstr(sn, "showAdFromRoot") || strstr(sn, "showFromRootViewController") ||
        strstr(sn, "showSplashAdFromRoot") || strstr(sn, "showSplashAdInWindow") ||
        strstr(sn, "loadAdData") || strstr(sn, "_loadAdData") ||
        strstr(sn, "setupSDKWithAppId") ||
        strstr(sn, "loadADWithPlacement") || strstr(sn, "loadAdWithPlacement") ||
        strstr(sn, "showInsertAds") || strstr(sn, "showInterstitial") ||
        strstr(sn, "loadInterstitial") || strstr(sn, "loadReward") ||
        strstr(sn, "showReward") || strstr(sn, "loadBanner") ||
        strstr(sn, "openScreenAds") || strstr(sn, "openScr") ||
        strcmp(sn, "isReady") == 0 || strcmp(sn, "isAdValid") == 0 ||
        strcmp(sn, "loadAD") == 0 || strcmp(sn, "showSplash") == 0 ||
        strcmp(sn, "showSplashAd") == 0 || strcmp(sn, "loadSplashAd") == 0;
}

static int hookAdSelectorsOnClass(Class cls, BOOL meta) {
    if (!cls) return 0;
    Class target = meta ? object_getClass((id)cls) : cls;
    if (!target) return 0;

    unsigned int count = 0;
    Method *list = class_copyMethodList(target, &count);
    if (!list) return 0;

    int n = 0;
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(list[i]);
        const char *sn = sel_getName(sel);
        if (!selectorLooksLikeAdControl(sn)) continue;

        if (kFakeReward) {
            const char *cn = class_getName(cls);
            if (cn && strstr(cn, "Reward") && strstr(sn, "load")) continue;
        }
        if (replaceMethod(cls, sel, meta)) n++;
    }
    free(list);
    return n;
}

static int hookClassByName(const char *cname) {
    Class cls = objc_getClass(cname);
    if (!cls) return 0;
    return hookAdSelectorsOnClass(cls, NO) + hookAdSelectorsOnClass(cls, YES);
}

#pragma mark - Known class table

static const char *kKnownClasses[] = {
    // WindMill / ToBid
    "WindMillAds",
    "WindMillSplashAd",
    "WindMillSplashAdManager",
    "WindMillIntersititialAd",
    "WindMillInterstitialAd",
    "WindMillInterstitialAdManager",
    "WindMillRewardVideoAd",
    "WindMillRewardVideoAdManager",
    "WindMillBannerView",
    "WindMillBannerAdManager",
    "WindMillNativeAdsManager",
    "WindMillNativeAdView",
    "WindAdManager",
    "WindSplashAdManager",
    "WindSplashAdView",
    "WindAds",
    "AWMWindSplashExpressAdManager",
    "AWMWindSplashNativeAdManager",
    "AWMKSCustomSplashAdapter",
    "AWMKSSplashExpressAdManager",
    "AWMAdScopeCustomSplashAdapter",
    "AWMAdScopeExpressSplashAdManager",
    "AWMAdScopeNativeSplashAdManager",
    "AWMKSCustomInterstitialAdapter",
    "AWMKSInterstitialAd",
    "AWMAdScopeCustomInterstitialAdapter",
    "AWMAdScopeExpressInterstitial",

    // UBiX
    "UbiXMSplashAdManager",
    "UBiXSplashAd",
    "UBiXMediationSplashAd",
    "UbiXMGDTSplashExpressAdapter",
    "UBiXMBaiduNativeAdapter",
    "UbiXMBaiduFeedExpressAdapter",

    // DCloud Uni
    "DCUniSplashAd",
    "DCUniInterstitialAd",
    "DCUniRewardedAd",
    "DCUniAdManager",
    "DCBasicSplashAd",
    "DCDcloudSplashAd",
    "DCBasicSplashAdLaunch",
    "DCBasicSplashAdViewController",
    "DCDcloudSplashAdViewController",

    // AnyThink / ToBid
    "ATAdManager",
    "ATSplash",
    "ATRewardedVideo",
    "ATInterstitial",
    "ATBanner",
    "ATNativeADManager",

    // 业务层
    "SplashAdManager",
    "FCSplashADSManager",
    "SplashAdLibHandler",
    "AdCenter",
    "AdsHandle",
    "AdsCNManager",
    "DSPAds",
    "OpenScrAdLibUBIX",
    "OpenScrAdLibToBid",
    "OpenScrLibNative",
    "InterstScrAdLibTaku",
    "InterstScrAdLibUBIX",
    "NativeSplashAdView",
    "SplashAdModel",
    "SplashAdBottomView",
    "DSPHomeAdsAlertView",
    "CheckOutAlertInsertADViewController",
    "LifeServiceHomeADPopAlertView",
    "CashDeskTakuADCell",
    "SendOrderAdBannerView",
    "BoxMobilePickADBannerView",
    "CheckoutAdFeedBannerCell",
    "WashSOAdsView",
    "AdMonitor",
    "HomeConfigUbixHandle",
    "HomeConfigUbixView",
    "HomeConfigDspView",

    // Swift mangled
    "_TtC12HiveConsumer15SplashAdManager",
    "_TtC12HiveConsumer18FCSplashADSManager",
    "_TtC12HiveConsumer18SplashAdLibHandler",
    "_TtC12HiveConsumer8AdCenter",
    "_TtC12HiveConsumer9AdsHandle",
    "_TtC12HiveConsumer12AdsCNManager",
    "_TtC12HiveConsumer6DSPAds",
    "_TtC12HiveConsumer16OpenScrAdLibUBIX",
    "_TtC12HiveConsumer17OpenScrAdLibToBid",
    "_TtC12HiveConsumer16OpenScrLibNative",
    "_TtC12HiveConsumer19InterstScrAdLibTaku",
    "_TtC12HiveConsumer19InterstScrAdLibUBIX",
    "_TtC12HiveConsumer18NativeSplashAdView",
    "_TtC12HiveConsumer13SplashAdModel",
    "_TtC12HiveConsumer18SplashAdBottomView",
    "_TtC12HiveConsumer19DSPHomeAdsAlertView",
    "_TtC12HiveConsumer35CheckOutAlertInsertADViewController",
    "_TtC12HiveConsumer29LifeServiceHomeADPopAlertView",
    "_TtC12HiveConsumer18CashDeskTakuADCell",
    "_TtC12HiveConsumer21SendOrderAdBannerView",
    "_TtC12HiveConsumer25BoxMobilePickADBannerView",
    "_TtC12HiveConsumer9AdMonitor",
    "_TtC12HiveConsumer20HomeConfigUbixHandle",
    "_TtC12HiveConsumer18HomeConfigUbixView",
    "_TtC12HiveConsumer17HomeConfigDspView",
    NULL
};

static int applyExactHooks(void) {
    int n = 0;
    const struct { const char *cls; const char *sel; BOOL meta; } exact[] = {
        { "WindMillAds", "setupSDKWithAppId:sdkConfigures:", YES },
        { "WindMillAds", "setupPrivacyServices", YES },
        { "WindMillSplashAd", "showAdInWindow:", NO },
        { "WindMillSplashAdManager", "showAdInWindow:", NO },
        { "WindMillSplashAdManager", "autoShowAd", NO },
        { "WindMillSplashAdManager", "showSplashAdFromRootViewController:adapter:nativeAds:", NO },
        { "UbiXMSplashAdManager", "loadSplash:withLifeModel:", NO },
        { "WindSplashAdManager", "loadFilterAndReturnError", NO },
        { "SMStoreProductViewController", "sm_loadProductWithAppId:timeout:params:finished:", NO },
        { "SMStoreProductViewController", "sm_loadProductWithAppId:timeout:type:params:finished:", NO },
        { "SMStoreProductViewController", "_sm_loadProductWithAPPID:timeout:params:finished:", NO },
        { NULL, NULL, NO }
    };
    for (int i = 0; exact[i].cls; i++) {
        n += hookSel(exact[i].cls, exact[i].sel, exact[i].meta);
    }
    return n;
}

static int applyKnownHooks(void) {
    int total = 0;
    for (int i = 0; kKnownClasses[i]; i++) {
        total += hookClassByName(kKnownClasses[i]);
    }
    total += applyExactHooks();
    return total;
}

#pragma mark - present 拦截

static void (*orig_present)(id, SEL, id, BOOL, id) = NULL;

static BOOL nameLooksLikeAdVC(const char *n) {
    if (!n) return NO;
    if (strstr(n, "SplashAd") || strstr(n, "Splash")) {
        if (strstr(n, "Wind") || strstr(n, "Mill") || strstr(n, "UBiX") || strstr(n, "UbiX") ||
            strstr(n, "ToBid") || strstr(n, "Sigmob") || strstr(n, "BeiZi") || strstr(n, "CSJ") ||
            strstr(n, "GDT") || strstr(n, "KS") || strstr(n, "BU") || strstr(n, "MS") ||
            strstr(n, "DC") || strstr(n, "Native") || strstr(n, "OpenScr") || strstr(n, "FCSplash") ||
            strstr(n, "AWM") || strstr(n, "AT") || strstr(n, "Ad")) {
            return YES;
        }
    }
    if (strstr(n, "Interstitial") || strstr(n, "Intersititial")) return YES;
    if (strstr(n, "InsertAD")) return YES;
    if (strstr(n, "DSPHomeAds")) return YES;
    if (strstr(n, "LifeServiceHomeAD")) return YES;
    if (strstr(n, "WindMill") && (strstr(n, "Ad") || strstr(n, "Native"))) return YES;
    if (strstr(n, "Reward") && strstr(n, "Ad")) return YES;
    if (strstr(n, "KSSplash") || strstr(n, "KSInterstitial")) return YES;
    if (strstr(n, "BUNative")) return YES;
    if (strstr(n, "GDT") && strstr(n, "Ad")) return YES;
    if (strstr(n, "CSJ") && strstr(n, "Ad")) return YES;
    if (strstr(n, "DCUniSplash") || strstr(n, "DCBasicSplash") || strstr(n, "DCDcloudSplash")) return YES;
    if (strstr(n, "StoreProduct") || strstr(n, "SKStoreProduct")) return YES;
    if (strstr(n, "SMStoreProduct")) return YES;
    if (strstr(n, "HomeConfigUbix") || strstr(n, "HomeConfigDsp")) return YES;
    return NO;
}

static void hooked_present(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL anim, id completion) {
    if (vc) {
        const char *n = class_getName(object_getClass(vc));
        if (nameLooksLikeAdVC(n)) {
            HCLog(@"block present %s", n);
            if (completion) ((void (^)(void))completion)();
            return;
        }
    }
    if (orig_present) orig_present(self, _cmd, vc, anim, completion);
}

static void installPresentHook(void) {
    Method m = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)hooked_present) return;
    orig_present = (void *)cur;
    method_setImplementation(m, (IMP)hooked_present);
}

#pragma mark - 外跳拦截 (广告 1s 后跳转别的 App / 商店)

// 仅拦明显广告外链，避免误伤支付宝/微信等业务跳转
static BOOL urlLooksLikeAdJump(NSURL *url) {
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *abs = url.absoluteString.lowercaseString ?: @"";

    // App Store / iTunes
    if ([scheme isEqualToString:@"itms-apps"] ||
        [scheme isEqualToString:@"itms-appss"] ||
        [scheme isEqualToString:@"itms"] ||
        [host containsString:@"apps.apple.com"] ||
        [host containsString:@"itunes.apple.com"]) {
        return YES;
    }

    // 常见广告落地 / 监测
    if ([abs containsString:@"adx"] || [abs containsString:@"ads."] ||
        [abs containsString:@"adn."] || [abs containsString:@"doubleclick"] ||
        [abs containsString:@"googlesyndication"] || [abs containsString:@"admob"] ||
        [abs containsString:@"gdt."] || [abs containsString:@"e.qq.com"] ||
        [abs containsString:@"pangolin"] || [abs containsString:@"pangle"] ||
        [abs containsString:@"csj."] || [abs containsString:@"snssdk"] ||
        [abs containsString:@"bytedance"] || [abs containsString:@"sigmob"] ||
        [abs containsString:@"windmill"] || [abs containsString:@"tobid"] ||
        [abs containsString:@"ubix"] || [abs containsString:@"beizi"] ||
        [abs containsString:@"kuaishou"] || [abs containsString:@"adkwai"] ||
        [abs containsString:@"adscope"] || [abs containsString:@"taku"] ||
        [abs containsString:@"toponad"] || [abs containsString:@"anythink"]) {
        return YES;
    }
    return NO;
}

static void (*orig_openURLOpts)(id, SEL, NSURL *, NSDictionary *, id) = NULL;
static BOOL (*orig_openURLLegacy)(id, SEL, NSURL *) = NULL;

static void hooked_openURLOpts(id self, SEL _cmd, NSURL *url, NSDictionary *opts, id completion) {
    if (urlLooksLikeAdJump(url)) {
        HCLog(@"block openURL %@", url);
        if (completion) {
            void (^cb)(BOOL) = completion;
            cb(NO);
        }
        return;
    }
    if (orig_openURLOpts) orig_openURLOpts(self, _cmd, url, opts, completion);
}

static BOOL hooked_openURLLegacy(id self, SEL _cmd, NSURL *url) {
    if (urlLooksLikeAdJump(url)) {
        HCLog(@"block openURL legacy %@", url);
        return NO;
    }
    if (orig_openURLLegacy) return orig_openURLLegacy(self, _cmd, url);
    return NO;
}

static void installOpenURLHooks(void) {
    Class cls = [UIApplication class];

    SEL selNew = @selector(openURL:options:completionHandler:);
    Method mNew = class_getInstanceMethod(cls, selNew);
    if (mNew) {
        IMP cur = method_getImplementation(mNew);
        if (cur != (IMP)hooked_openURLOpts) {
            orig_openURLOpts = (void *)cur;
            method_setImplementation(mNew, (IMP)hooked_openURLOpts);
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    SEL selOld = @selector(openURL:);
#pragma clang diagnostic pop
    Method mOld = class_getInstanceMethod(cls, selOld);
    if (mOld) {
        IMP cur = method_getImplementation(mOld);
        if (cur != (IMP)hooked_openURLLegacy) {
            orig_openURLLegacy = (void *)cur;
            method_setImplementation(mOld, (IMP)hooked_openURLLegacy);
        }
    }
}

#pragma mark - 广告 View 折叠

static void hideIfNeeded(UIView *v) {
    v.hidden = YES;
    v.alpha = 0;
    v.userInteractionEnabled = NO;
    CGRect f = v.frame;
    if (f.size.height > 0.5) {
        f.size.height = 0;
        v.frame = f;
    }
}

static void hooked_didMove(UIView *self, SEL _cmd) {
    static void (*uiViewDidMove)(id, SEL) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method root = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
        if (root) uiViewDidMove = (void *)method_getImplementation(root);
    });
    if (uiViewDidMove) uiViewDidMove(self, _cmd);
    if (self.window) hideIfNeeded(self);
}

static void swizzleDidMoveOnClass(const char *cname) {
    Class cls = objc_getClass(cname);
    if (!cls || ![cls isSubclassOfClass:[UIView class]]) return;

    SEL sel = @selector(didMoveToWindow);
    Method root = class_getInstanceMethod([UIView class], sel);
    if (!root) return;
    const char *enc = method_getTypeEncoding(root);

    if (!class_addMethod(cls, sel, (IMP)hooked_didMove, enc)) {
        Method m = class_getInstanceMethod(cls, sel);
        if (m && method_getImplementation(m) != (IMP)hooked_didMove) {
            method_setImplementation(m, (IMP)hooked_didMove);
        }
    }
}

static const char *kAdViews[] = {
    "NativeSplashAdView",
    "_TtC12HiveConsumer18NativeSplashAdView",
    "SplashAdBottomView",
    "_TtC12HiveConsumer18SplashAdBottomView",
    "DSPHomeAdsAlertView",
    "_TtC12HiveConsumer19DSPHomeAdsAlertView",
    "CashDeskTakuADCell",
    "_TtC12HiveConsumer18CashDeskTakuADCell",
    "SendOrderAdBannerView",
    "_TtC12HiveConsumer21SendOrderAdBannerView",
    "BoxMobilePickADBannerView",
    "_TtC12HiveConsumer25BoxMobilePickADBannerView",
    "BoxMobilePickADBannerTopView",
    "_TtC12HiveConsumer28BoxMobilePickADBannerTopView",
    "BoxMobilePickADBannerLeftView",
    "_TtC12HiveConsumer29BoxMobilePickADBannerLeftView",
    "CheckoutAdFeedBannerCell",
    "_TtC12HiveConsumer24CheckoutAdFeedBannerCell",
    "CheckoutAdFeedGoodsCell",
    "_TtC12HiveConsumer23CheckoutAdFeedGoodsCell",
    "CheckoutAdFeedMixBannerCell",
    "_TtC12HiveConsumer27CheckoutAdFeedMixBannerCell",
    "WashSOAdsView",
    "_TtC12HiveConsumer13WashSOAdsView",
    "LSOrderPayAdImageView",
    "_TtC12HiveConsumer21LSOrderPayAdImageView",
    "LifeServiceHomeADPopAlertView",
    "_TtC12HiveConsumer29LifeServiceHomeADPopAlertView",
    "HomeConfigUbixView",
    "_TtC12HiveConsumer18HomeConfigUbixView",
    "HomeConfigDspView",
    "_TtC12HiveConsumer17HomeConfigDspView",
    "HomeConfigUbixContentView",
    "_TtC12HiveConsumer25HomeConfigUbixContentView",
    "HomeConfigUbixMainImageView",
    "_TtC12HiveConsumer27HomeConfigUbixMainImageView",
    "WindMillBannerView",
    "WindMillNativeAdView",
    "WindSplashAdView",
    "WindSplashTemplateView",
    "GDTUnifiedNativeAdView",
    "CSJNativeExpressAdView",
    NULL
};

static void installViewHooks(void) {
    for (int i = 0; kAdViews[i]; i++) {
        swizzleDidMoveOnClass(kAdViews[i]);
    }
}

#pragma mark - Main tab cleanup

// 自定义 TabBar 依赖固定 5 个控制器索引；删除会错位。
// 保留顺序，隐藏 1 洗衣、2 会员，并将 0/3/4 三等分。
static void (*orig_mainTabViewDidLayoutSubviews)(id, SEL) = NULL;
static char kMainTabButtonsKey;

static BOOL classNameContains(UIView *view, const char *fragment) {
    const char *name = class_getName(object_getClass(view));
    return name && strstr(name, fragment);
}

static NSArray<UIView *> *sortedTabViews(NSArray<UIView *> *views) {
    return [views sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        if (a.frame.origin.x < b.frame.origin.x) return NSOrderedAscending;
        if (a.frame.origin.x > b.frame.origin.x) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static NSArray<UIView *> *mainTabButtons(UITabBar *tabBar) {
    NSArray<UIView *> *saved = objc_getAssociatedObject(tabBar, &kMainTabButtonsKey);
    if (saved.count == 5) {
        BOOL valid = YES;
        for (UIView *button in saved) {
            if (button.superview != tabBar) { valid = NO; break; }
        }
        if (valid) return saved;
    }

    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *view in tabBar.subviews) {
        if (classNameContains(view, "MainTabBarItemContentView")) {
            [buttons addObject:view];
        }
    }
    if (buttons.count != 5) {
        [buttons removeAllObjects];
        for (UIView *view in tabBar.subviews) {
            const char *name = class_getName(object_getClass(view));
            if (name && strcmp(name, "UITabBarButton") == 0) {
                [buttons addObject:view];
            }
        }
    }
    if (buttons.count != 5) return @[];

    NSArray<UIView *> *sorted = sortedTabViews(buttons);
    objc_setAssociatedObject(tabBar, &kMainTabButtonsKey, sorted, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return sorted;
}

static void layoutThreeMainTabs(UITabBar *tabBar) {
    NSArray<UIView *> *buttons = mainTabButtons(tabBar);
    if (buttons.count != 5) return;

    CGFloat width = tabBar.bounds.size.width / 3.0;
    NSUInteger visibleIndex = 0;
    for (NSUInteger index = 0; index < buttons.count; index++) {
        UIView *button = buttons[index];
        BOOL hide = index == 1 || index == 2;
        button.hidden = hide;
        button.userInteractionEnabled = !hide;
        if (hide) continue;

        CGRect frame = button.frame;
        frame.origin.x = width * visibleIndex;
        frame.size.width = width;
        button.frame = frame;
        visibleIndex++;
    }
}

static void hc_mainTabViewDidLayoutSubviews(UITabBarController *self, SEL cmd) {
    if (orig_mainTabViewDidLayoutSubviews) orig_mainTabViewDidLayoutSubviews(self, cmd);
    layoutThreeMainTabs(self.tabBar);
}

static Class mainTabBarControllerClass(void) {
    Class cls = objc_getClass("MainTabBarController");
    if (!cls) cls = objc_getClass("_TtC12HiveConsumer20MainTabBarController");
    return cls;
}

static void installMainTabHooks(void) {
    Class cls = mainTabBarControllerClass();
    if (!cls || ![cls isSubclassOfClass:[UITabBarController class]]) return;

    SEL layoutSel = @selector(viewDidLayoutSubviews);
    IMP current = class_getMethodImplementation(cls, layoutSel);
    if (current && current != (IMP)hc_mainTabViewDidLayoutSubviews) {
        Method method = class_getInstanceMethod(cls, layoutSel);
        if (!method) return;
        orig_mainTabViewDidLayoutSubviews = (void *)current;
        if (!class_addMethod(cls, layoutSel, (IMP)hc_mainTabViewDidLayoutSubviews,
                             method_getTypeEncoding(method))) {
            method_setImplementation(method, (IMP)hc_mainTabViewDidLayoutSubviews);
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            UIViewController *root = window.rootViewController;
            NSMutableArray<UIViewController *> *queue = [NSMutableArray array];
            if (root) [queue addObject:root];
            while (queue.count) {
                UIViewController *vc = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([vc isKindOfClass:cls]) {
                    UITabBarController *tabs = (UITabBarController *)vc;
                    [tabs.tabBar setNeedsLayout];
                    [tabs.tabBar layoutIfNeeded];
                    layoutThreeMainTabs(tabs.tabBar);
                    return;
                }
                if (vc.presentedViewController) [queue addObject:vc.presentedViewController];
                [queue addObjectsFromArray:vc.childViewControllers];
            }
        }
    });
}

#pragma mark - Entry / 回前台补 hook

static void applyAll(const char *tag) {
    int n = applyKnownHooks();
    installMainTabHooks();
    installOpenURLHooks();
    installPresentHook();
    installViewHooks();
    HCLog(@"%s hooks=%d", tag, n);
}

static void onForeground(void) {
    // 热启动开屏常在回前台瞬间触发；立刻 + 0.3s 再补，拦住懒加载类
    applyAll("foreground");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        applyAll("foreground+0.3s");
    });
}

static void installForegroundObserver(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                    object:nil queue:nil
                usingBlock:^(__unused NSNotification *note) {
        onForeground();
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:nil
                usingBlock:^(__unused NSNotification *note) {
        // becomeActive 再补一次，覆盖部分 SDK 的 active 触发路径
        applyAll("active");
    }];
}

__attribute__((constructor))
static void HiveConsumerDylibInit(void) {
    @autoreleasepool {
        installPresentHook();
        installOpenURLHooks();
        applyAll("ctor");
        installForegroundObserver();

        dispatch_async(dispatch_get_main_queue(), ^{
            applyAll("main");
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            applyAll("+1.5s");
        });

        // 久置场景: 5s 后再补一次，覆盖更晚懒加载的 UBiX/ToBid 类
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            applyAll("+5s");
        });
    }
}
