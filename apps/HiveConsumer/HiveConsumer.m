//
// HiveConsumer.dylib — 丰巢去广告 (TrollFools)
// Bundle: com.fcbox.hiveconsumer | 分析版本: 6.32.0
//
// v3.1: 修复注入闪退
//   - 不 hook 参数过多 / 非 id·BOOL·void 签名的方法（避免 stub ABI 崩）
//   - openURL 延后到主线程、严格类型检查
//   - 回前台只补已知类，不做危险全量替换
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

#pragma mark - Stubs (仅支持 void / BOOL / id，且参数 ≤5 个业务参数)

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

/// 只接受「返回 void/BOOL/id」且「参数全是指针/id」的简单方法，避免 double/struct 崩
static BOOL encodingIsSafe(const char *enc, unsigned argc) {
    if (!enc || !enc[0]) return NO;
    // 业务参数过多时 arm64 寄存器/栈约定复杂，跳过
    // argc 含 self + _cmd
    if (argc > 7) return NO; // 最多 5 个业务参数

    char ret = enc[0];
    if (ret != 'v' && ret != 'B' && ret != 'c' && ret != '@') return NO;

    // 粗查：编码串里若出现 float/double/struct 返回或参数则跳过
    // 典型: d f {CGRect  N  ...
    if (strchr(enc, 'd') || strchr(enc, 'f')) {
        // BOOL 有时是 c，id 协议里可能有，但 d/f 基本是数值 —— 仍可能误伤
        // 更严：只允许 v@:@ 这类；若含 d/f 直接拒绝
        return NO;
    }
    if (strchr(enc, '{') || strchr(enc, '(')) return NO;
    return YES;
}

static IMP stubForEncoding(const char *enc, unsigned argc) {
    if (!encodingIsSafe(enc, argc)) return NULL;
    char r = enc[0];
    if (r == 'v') {
        if (argc <= 2) return (IMP)stub_v0;
        if (argc == 3) return (IMP)stub_v1;
        if (argc == 4) return (IMP)stub_v2;
        if (argc == 5) return (IMP)stub_v3;
        if (argc == 6) return (IMP)stub_v4;
        return (IMP)stub_v5; // argc == 7
    }
    if (r == 'B' || r == 'c') {
        // 仅无参 isReady / isAdValid
        if (argc != 2) return NULL;
        return (IMP)stub_NO;
    }
    if (r == '@') {
        if (argc <= 2) return (IMP)stub_nil0;
        if (argc == 3) return (IMP)stub_nil1;
        if (argc == 4) return (IMP)stub_nil2;
        return NULL;
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
    IMP old = method_getImplementation(m);
    if (old == imp) return YES;
    method_setImplementation(m, imp);
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
        strstr(sn, "showInsertAds") ||
        strstr(sn, "openScreenAds") ||
        strcmp(sn, "isReady") == 0 || strcmp(sn, "isAdValid") == 0 ||
        strcmp(sn, "loadAD") == 0 ||
        strcmp(sn, "showSplash") == 0 ||
        strcmp(sn, "showSplashAd") == 0 ||
        strcmp(sn, "loadSplashAd") == 0 ||
        strcmp(sn, "autoShowAd") == 0;
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
        // 直接用 list[i] 的 encoding，避免再查
        const char *enc = method_getTypeEncoding(list[i]);
        unsigned argc = method_getNumberOfArguments(list[i]);
        IMP imp = stubForEncoding(enc, argc);
        if (!imp) continue;
        if (method_getImplementation(list[i]) != imp) {
            method_setImplementation(list[i], imp);
            n++;
        }
    }
    free(list);
    return n;
}

static int hookClassByName(const char *cname) {
    Class cls = objc_getClass(cname);
    if (!cls) return 0;
    return hookAdSelectorsOnClass(cls, NO) + hookAdSelectorsOnClass(cls, YES);
}

#pragma mark - Known classes

static const char *kKnownClasses[] = {
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

    "UbiXMSplashAdManager",
    "UBiXSplashAd",
    "UBiXMediationSplashAd",
    "UbiXMGDTSplashExpressAdapter",

    "DCUniSplashAd",
    "DCUniInterstitialAd",
    "DCUniRewardedAd",
    "DCUniAdManager",
    "DCBasicSplashAd",
    "DCDcloudSplashAd",
    "DCBasicSplashAdLaunch",
    "DCBasicSplashAdViewController",
    "DCDcloudSplashAdViewController",

    "ATAdManager",
    "ATSplash",
    "ATRewardedVideo",
    "ATInterstitial",
    "ATBanner",

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
    // 仅 hook 签名简单的方法（无 double/struct）
    const struct { const char *cls; const char *sel; BOOL meta; } exact[] = {
        { "WindMillAds", "setupSDKWithAppId:sdkConfigures:", YES },
        { "WindMillAds", "setupPrivacyServices", YES },
        { "WindMillSplashAd", "showAdInWindow:", NO },
        { "WindMillSplashAdManager", "showAdInWindow:", NO },
        { "WindMillSplashAdManager", "autoShowAd", NO },
        { "WindMillSplashAdManager", "showSplashAdFromRootViewController:adapter:nativeAds:", NO },
        { "UbiXMSplashAdManager", "loadSplash:withLifeModel:", NO },
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

#pragma mark - present

static void (*orig_present)(id, SEL, id, BOOL, id) = NULL;

static BOOL nameLooksLikeAdVC(const char *n) {
    if (!n) return NO;
    if (strstr(n, "SplashAd")) return YES;
    if (strstr(n, "WindMillSplash") || strstr(n, "WindSplash")) return YES;
    if (strstr(n, "UBiX") && strstr(n, "Splash")) return YES;
    if (strstr(n, "UbiX") && strstr(n, "Splash")) return YES;
    if (strstr(n, "Interstitial") || strstr(n, "Intersititial")) return YES;
    if (strstr(n, "InsertAD")) return YES;
    if (strstr(n, "DSPHomeAds")) return YES;
    if (strstr(n, "LifeServiceHomeAD")) return YES;
    if (strstr(n, "WindMill") && strstr(n, "Ad")) return YES;
    if (strstr(n, "Reward") && strstr(n, "Ad") && strstr(n, "ViewController")) return YES;
    if (strstr(n, "KSSplash") || strstr(n, "KSInterstitial")) return YES;
    if (strstr(n, "GDTSplash") || strstr(n, "GDTUnified")) return YES;
    if (strstr(n, "BUSplash") || strstr(n, "CSJSplash")) return YES;
    if (strstr(n, "DCUniSplash") || strstr(n, "DCBasicSplash") || strstr(n, "DCDcloudSplash")) return YES;
    if (strstr(n, "SMStoreProduct") || strstr(n, "SKStoreProduct")) return YES;
    if (strstr(n, "OpenScr") && strstr(n, "Ad")) return YES;
    return NO;
}

static void hooked_present(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL anim, id completion) {
    if (vc) {
        const char *n = class_getName(object_getClass(vc));
        if (nameLooksLikeAdVC(n)) {
            HCLog(@"block present %s", n);
            if (completion) {
                @try { ((void (^)(void))completion)(); } @catch (__unused NSException *e) {}
            }
            return;
        }
    }
    if (orig_present) orig_present(self, _cmd, vc, anim, completion);
}

static void installPresentHook(void) {
    Method m = class_getInstanceMethod([UIViewController class],
                                       @selector(presentViewController:animated:completion:));
    if (!m) return;
    IMP cur = method_getImplementation(m);
    if (cur == (IMP)hooked_present) return;
    orig_present = (void *)cur;
    method_setImplementation(m, (IMP)hooked_present);
}

#pragma mark - openURL（防广告外跳，严格安全）

static void (*orig_openURLOpts)(id, SEL, id, id, id) = NULL;
static BOOL (*orig_openURLLegacy)(id, SEL, id) = NULL;
static volatile BOOL gOpenURLHookReady = NO;

static BOOL urlLooksLikeAdJump(id urlObj) {
    if (!urlObj || ![urlObj isKindOfClass:[NSURL class]]) return NO;
    NSURL *url = (NSURL *)urlObj;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    NSString *host = url.host.lowercaseString ?: @"";
    NSString *abs = url.absoluteString.lowercaseString ?: @"";

    if ([scheme isEqualToString:@"itms-apps"] ||
        [scheme isEqualToString:@"itms-appss"] ||
        [scheme isEqualToString:@"itms"]) {
        return YES;
    }
    if ([host containsString:@"apps.apple.com"] ||
        [host containsString:@"itunes.apple.com"]) {
        return YES;
    }
    // 常见广告监测 / 聚合域名（尽量不误伤业务 deep link）
    static NSString * const keys[] = {
        @"googlesyndication", @"doubleclick", @"admob",
        @"pangolin", @"pangle.io", @"snssdk.com",
        @"gdt.qq.com", @"e.qq.com", @"l.qq.com",
        @"sigmob", @"windmill-ad", @"tobid.cn", @"ubixio.com",
        @"beizi.biz", @"adscope", @"toponad", @"anythinktech",
        @"adkwai", @"kuaishou.com/ad",
        nil
    };
    for (int i = 0; keys[i]; i++) {
        if ([abs containsString:keys[i]]) return YES;
    }
    return NO;
}

static void hooked_openURLOpts(id self, SEL _cmd, id url, id opts, id completion) {
    if (gOpenURLHookReady && urlLooksLikeAdJump(url)) {
        HCLog(@"block openURL %@", url);
        if (completion && [completion isKindOfClass:NSClassFromString(@"NSBlock")]) {
            @try { ((void (^)(BOOL))completion)(NO); } @catch (__unused NSException *e) {}
        }
        return;
    }
    if (orig_openURLOpts) orig_openURLOpts(self, _cmd, url, opts, completion);
}

static BOOL hooked_openURLLegacy(id self, SEL _cmd, id url) {
    if (gOpenURLHookReady && urlLooksLikeAdJump(url)) {
        HCLog(@"block openURL legacy %@", url);
        return NO;
    }
    if (orig_openURLLegacy) return orig_openURLLegacy(self, _cmd, url);
    return NO;
}

static void installOpenURLHooks(void) {
    Class cls = [UIApplication class];
    if (!cls) return;

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

#pragma mark - Ad views

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
    if (!cls) return;
    // isSubclassOfClass 在构造早期 UIKit 未就绪时可能有问题，包一层
    @try {
        if (![cls isSubclassOfClass:[UIView class]]) return;
    } @catch (__unused NSException *e) { return; }

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
    "GDTUnifiedNativeAdView",
    "CSJNativeExpressAdView",
    NULL
};

static void installViewHooks(void) {
    for (int i = 0; kAdViews[i]; i++) {
        swizzleDidMoveOnClass(kAdViews[i]);
    }
}

#pragma mark - Main tab (隐藏洗衣/会员，不删 VC)

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
        BOOL hide = (index == 1 || index == 2);
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
    @try { layoutThreeMainTabs(self.tabBar); } @catch (__unused NSException *e) {}
}

static Class mainTabBarControllerClass(void) {
    Class cls = objc_getClass("MainTabBarController");
    if (!cls) cls = objc_getClass("_TtC12HiveConsumer20MainTabBarController");
    return cls;
}

static void installMainTabHooks(void) {
    Class cls = mainTabBarControllerClass();
    if (!cls) return;
    @try {
        if (![cls isSubclassOfClass:[UITabBarController class]]) return;
    } @catch (__unused NSException *e) { return; }

    SEL layoutSel = @selector(viewDidLayoutSubviews);
    Method method = class_getInstanceMethod(cls, layoutSel);
    if (!method) return;
    IMP current = method_getImplementation(method);
    if (current == (IMP)hc_mainTabViewDidLayoutSubviews) return;

    orig_mainTabViewDidLayoutSubviews = (void *)current;
    if (!class_addMethod(cls, layoutSel, (IMP)hc_mainTabViewDidLayoutSubviews,
                         method_getTypeEncoding(method))) {
        method_setImplementation(method, (IMP)hc_mainTabViewDidLayoutSubviews);
    }
}

#pragma mark - Entry

static void applyAll(const char *tag) {
    @try {
        int n = applyKnownHooks();
        installMainTabHooks();
        installViewHooks();
        HCLog(@"%s hooks=%d", tag, n);
    } @catch (NSException *e) {
        HCLog(@"%s exception %@", tag, e);
    }
}

static void onForeground(void) {
    applyAll("foreground");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        applyAll("foreground+0.3s");
    });
}

static void installForegroundObserver(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) { onForeground(); }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *note) { applyAll("active"); }];
}

__attribute__((constructor))
static void HiveConsumerDylibInit(void) {
    @autoreleasepool {
        // 构造期只装最安全的 present；其余放到主线程，避免 UIKit 未就绪 / ABI 问题
        @try { installPresentHook(); } @catch (__unused NSException *e) {}

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                installOpenURLHooks();
                gOpenURLHookReady = YES;
                applyAll("main");
                installForegroundObserver();
            } @catch (__unused NSException *e) {}
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            applyAll("+1.5s");
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            applyAll("+5s");
        });
    }
}
