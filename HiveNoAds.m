//
// HiveNoAds — 丰巢 HiveConsumer 去广告 dylib (TrollFools / 无 Substrate)
// Bundle: com.fcbox.hiveconsumer
// 基于 6.32.0 解密二进制静态分析
//
// 纯 Objective-C + method_setImplementation，不依赖 MobileSubstrate/ElleKit。
// 用 TrollFools 注入到 HiveConsumer 即可。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <os/log.h>

#pragma mark - Config

/// 1 = 激励视频尝试假装发奖（实验）；0 = 只禁止展示（推荐）
static const BOOL kHiveNoAdsFakeReward = NO;
static const BOOL kHiveNoAdsVerbose = YES;

#define HNALog(fmt, ...) do { \
    if (kHiveNoAdsVerbose) NSLog(@"[HiveNoAds] " fmt, ##__VA_ARGS__); \
} while (0)

#pragma mark - Stubs

static void HNA_void0(id self, SEL _cmd) {
    HNALog(@"nop -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}
static void HNA_void1(id self, SEL _cmd, id a) {
    HNALog(@"nop -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}
static void HNA_void2(id self, SEL _cmd, id a, id b) {
    HNALog(@"nop -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}
static void HNA_void3(id self, SEL _cmd, id a, id b, id c) {
    HNALog(@"nop -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}
static void HNA_void4(id self, SEL _cmd, id a, id b, id c, id d) {
    HNALog(@"nop -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}
static BOOL HNA_boolNO(id self, SEL _cmd) {
    HNALog(@"=> NO -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
    return NO;
}
static BOOL HNA_boolYES(id self, SEL _cmd) {
    return YES;
}
static id HNA_idNil(id self, SEL _cmd) { return nil; }
static id HNA_idNil1(id self, SEL _cmd, id a) { return nil; }

static void HNAReplaceMethod(Class cls, SEL sel, BOOL isClassMethod) {
    if (!cls || !sel) return;
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *type = method_getTypeEncoding(m);
    if (!type || type[0] == '\0') return;

    unsigned n = method_getNumberOfArguments(m);
    IMP imp = NULL;
    char ret = type[0];

    if (ret == 'v') {
        if (n <= 2) imp = (IMP)HNA_void0;
        else if (n == 3) imp = (IMP)HNA_void1;
        else if (n == 4) imp = (IMP)HNA_void2;
        else if (n == 5) imp = (IMP)HNA_void3;
        else imp = (IMP)HNA_void4;
    } else if (ret == 'B' || ret == 'c') {
        NSString *name = NSStringFromSelector(sel);
        if ([name containsString:@"isVip"] || [name containsString:@"adFree"] ||
            [name containsString:@"isMember"] || [name containsString:@"hasVip"]) {
            imp = (IMP)HNA_boolYES;
        } else {
            imp = (IMP)HNA_boolNO;
        }
    } else if (ret == '@') {
        imp = (n <= 2) ? (IMP)HNA_idNil : (IMP)HNA_idNil1;
    } else {
        return;
    }

    IMP old = method_getImplementation(m);
    if (old == imp) return;
    method_setImplementation(m, imp);
    HNALog(@"hook %c[%@ %@]", isClassMethod ? '+' : '-', NSStringFromClass(cls), NSStringFromSelector(sel));
}

static BOOL HNATryHook(const char *className, const char *selName, BOOL isClassMethod) {
    Class cls = objc_getClass(className);
    if (!cls) return NO;
    SEL sel = sel_registerName(selName);
    if (!class_respondsToSelector(isClassMethod ? object_getClass((id)cls) : cls, sel) &&
        !(isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel))) {
        // still try — some methods only on subclass
        Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
        if (!m) return NO;
    }
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    HNAReplaceMethod(cls, sel, isClassMethod);
    return YES;
}

#pragma mark - Class / selector heuristics

static BOOL HNAClassNameLooksLikeAd(NSString *name) {
    if (name.length == 0) return NO;
    if ([name containsString:@"Address"] || [name containsString:@"Adress"]) return NO;
    if ([name containsString:@"AddService"] || [name containsString:@"AddTime"] ||
        [name containsString:@"AddPhoto"] || [name containsString:@"AddParams"]) return NO;

    static NSArray<NSString *> *pos;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pos = @[
            @"WindMill", @"WindSplash", @"WindAd", @"WindNative",
            @"SplashAd", @"RewardVideo", @"RewardedVideo", @"Interstitial",
            @"InterstScrAd", @"OpenScrAd", @"NativeSplash",
            @"BannerAd", @"NativeAd", @"AdsCN", @"AdCenter", @"AdsHandle",
            @"DSPAds", @"DSPHomeAds", @"TakuAD", @"InsertAD",
            @"HomeAD", @"PayAd", @"SOAds", @"ADBanner", @"AdBanner",
            @"AdFeed", @"Advert", @"GDT", @"CSJ", @"BUNative", @"BUAd",
            @"KSAd", @"KSSplash", @"KSInterstitial", @"KSReward",
            @"DCUniSplash", @"DCUniInterstitial", @"DCUniReward",
            @"DCBasicSplash", @"DCDcloudSplash", @"DCUniAd",
            @"UBiX", @"UbiXM", @"ToBid", @"AnyThink", @"ATSplash",
            @"ATBanner", @"ATRewarded", @"ATInterstitial", @"ATNative",
            @"FCSplashADS", @"MeiShuSplash", @"FancySplash", @"FancyReward",
            @"FancyNative", @"BaiduMobAd", @"GMSplash", @"GMNative",
            @"MSSplash", @"MSBanner", @"MSInterstitial", @"MSNative", @"MSReward",
            @"PTGSplash", @"PTGNative", @"JADNative", @"JADInterstitial",
            @"AdView", @"AdManager", @"AdLoader", @"AdService",
            @"CheckoutAd", @"CashDeskTaku", @"BoxMobilePickAD",
            @"SendOrderAd", @"WashSOAds", @"WashImportSendAds",
            @"LifeServiceHomeAD", @"LSOrderPayAd", @"LifeServiceDetailAd",
            @"NativeSplashAdView", @"SplashAdBottom", @"SplashAdLib",
            @"SplashAdManager", @"SplashAdModel", @"SplashAdTracker",
            @"SplashAdScreenShot", @"AdsCashDesk", @"AdMonitor",
            @"HomeBannerAdvert",
        ];
    });
    for (NSString *p in pos) {
        if ([name containsString:p]) return YES;
    }
    if ([name containsString:@"Ads"] || [name containsString:@"Advert"]) return YES;
    if ([name hasSuffix:@"Ad"] && ![name containsString:@"Trade"] && ![name containsString:@"Upload"]) {
        return YES;
    }
    return NO;
}

static BOOL HNASelectorLooksLikeAdControl(SEL sel) {
    if (!sel) return NO;
    NSString *s = NSStringFromSelector(sel);
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"loadAd", @"loadAD", @"LoadAd", @"loadData",
            @"showAd", @"showAD", @"ShowAd",
            @"showSplash", @"loadSplash", @"autoShowAd",
            @"showFromRoot", @"showAdFromRoot", @"showAdInWindow",
            @"showBanner", @"showInterstitial", @"showReward",
            @"showRewarded", @"presentAd", @"displayAd",
            @"requestAd", @"fetchAd", @"playAd",
            @"isReady", @"isAdValid",
            @"startSplash", @"openSplash", @"playSplash",
            @"loadWithPlacement", @"loadAdWith", @"loadAdData",
            @"_loadAdData", @"loadFilter", @"setupSDKWithAppId",
        ];
    });
    for (NSString *k in keys) {
        if ([s containsString:k]) return YES;
    }
    return NO;
}

static BOOL HNAViewClassShouldHide(NSString *name) {
    if (!HNAClassNameLooksLikeAd(name)) return NO;
    if ([name containsString:@"Manager"] || [name containsString:@"Model"] ||
        [name containsString:@"Protocol"] || [name containsString:@"Delegate"] ||
        [name containsString:@"Request"] || [name containsString:@"Config"] ||
        [name containsString:@"Tracker"] || [name containsString:@"Monitor"] ||
        [name containsString:@"Adapter"] || [name containsString:@"Strategy"]) {
        return NO;
    }
    if ([name containsString:@"View"] || [name containsString:@"Cell"] ||
        [name containsString:@"Controller"] || [name containsString:@"Alert"] ||
        [name containsString:@"Banner"] || [name containsString:@"Window"]) {
        return YES;
    }
    return NO;
}

static BOOL HNAShouldForceHideViewName(NSString *name) {
    if (HNAViewClassShouldHide(name)) return YES;
    static NSArray<NSString *> *exactish;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactish = @[
            @"NativeSplashAdView", @"SplashAdBottom", @"CashDeskTakuAD",
            @"CheckoutAdFeed", @"BoxMobilePickAD", @"SendOrderAdBanner",
            @"WashSOAds", @"DSPHomeAds", @"LifeServiceHomeAD", @"LSOrderPayAd",
            @"CheckOutAlertInsertAD", @"OpenScrAd", @"InterstScrAd",
            @"WindMillBanner", @"WindMillNative", @"GDTUnifiedNative",
            @"CSJNative", @"BUNativeExpress", @"KSAd",
        ];
    });
    for (NSString *p in exactish) {
        if ([name containsString:p]) return YES;
    }
    return NO;
}

#pragma mark - Explicit WindMill / DCUni hooks

static void HNAHookKnownSDK(void) {
    struct {
        const char *cls;
        const char *sel;
        BOOL meta;
    } table[] = {
        // WindMill init
        { "WindMillAds", "setupSDKWithAppId:sdkConfigures:", YES },
        { "WindMillAds", "setupPrivacyServices", YES },
        { "WindMillAds", "initDclogAndTrackQueueService", YES },

        // Splash
        { "WindMillSplashAd", "loadAdData", NO },
        { "WindMillSplashAd", "loadAdData:", NO },
        { "WindMillSplashAd", "_loadAdData:", NO },
        { "WindMillSplashAd", "showAdInWindow:", NO },
        { "WindMillSplashAd", "isReady", NO },
        { "WindMillSplashAd", "isAdValid", NO },
        { "WindMillSplashAdManager", "showAdInWindow:", NO },
        { "WindMillSplashAdManager", "autoShowAd", NO },
        { "WindMillSplashAdManager", "showSplashAdFromRootViewController:adapter:nativeAds:", NO },

        // Interstitial (SDK 拼写 Intersititial)
        { "WindMillIntersititialAd", "loadAdData", NO },
        { "WindMillIntersititialAd", "loadAdData:", NO },
        { "WindMillIntersititialAd", "_loadAdData:", NO },
        { "WindMillIntersititialAd", "showAdFromRootViewController:", NO },
        { "WindMillIntersititialAd", "showAdFromRootViewController:options:", NO },
        { "WindMillIntersititialAd", "isReady", NO },
        { "WindMillIntersititialAd", "isAdValid", NO },
        { "WindMillInterstitialAdManager", "showAdFromRootViewController:options:", NO },
        { "WindMillInterstitialAdManager", "showAdFromRootViewController:adapter:nativeAds:", NO },

        // Reward
        { "WindMillRewardVideoAd", "loadAdData", NO },
        { "WindMillRewardVideoAd", "loadAdData:", NO },
        { "WindMillRewardVideoAd", "_loadAdData:", NO },
        { "WindMillRewardVideoAd", "showAdFromRootViewController:", NO },
        { "WindMillRewardVideoAd", "showAdFromRootViewController:options:", NO },
        { "WindMillRewardVideoAd", "isReady", NO },
        { "WindMillRewardVideoAd", "isAdValid", NO },
        { "WindMillRewardVideoAdManager", "showAdFromRootViewController:options:", NO },
        { "WindMillRewardVideoAdManager", "showAdFromRootViewController:adapter:nativeAds:", NO },

        // Banner / Native
        { "WindMillBannerView", "loadAdData", NO },
        { "WindMillBannerView", "loadAdData:", NO },
        { "WindMillBannerView", "isReady", NO },
        { "WindMillBannerAdManager", "showAdFromRootViewController:adapter:nativeAds:", NO },
        { "WindMillBannerAdManager", "restartRefreshTimer", NO },
        { "WindMillNativeAdsManager", "loadAdData", NO },
        { "WindMillNativeAdsManager", "loadAdData:", NO },

        // Legacy Wind*
        { "WindAdManager", "showAdFromRootViewController:options:", NO },
        { "WindAdManager", "loadFilterAndReturnError", NO },
        { "WindSplashAdManager", "loadFilterAndReturnError", NO },

        // DCloud Uni
        { "DCUniSplashAd", "loadAdData", NO },
        { "DCUniSplashAd", "showAdInWindow:", NO },
        { "DCUniSplashAd", "showSplashAdInWindow:", NO },
        { "DCUniSplashAd", "isReady", NO },
        { "DCUniInterstitialAd", "loadAdData", NO },
        { "DCUniInterstitialAd", "showAdFromRootViewController:", NO },
        { "DCUniInterstitialAd", "isReady", NO },
        { "DCUniRewardedAd", "loadAdData", NO },
        { "DCUniRewardedAd", "showAdFromRootViewController:", NO },
        { "DCUniRewardedAd", "isReady", NO },
        { "DCBasicSplashAd", "loadAdData", NO },
        { "DCDcloudSplashAd", "loadAdData", NO },

        // AnyThink common
        { "ATAdManager", "loadADWithPlacementID:extra:delegate:", NO },
        { "ATAdManager", "showSplashWithPlacementID:extra:window:delegate:", NO },

        { NULL, NULL, NO }
    };

    for (int i = 0; table[i].cls; i++) {
        // 激励：若 FakeReward，跳过 load 的阻断（仍阻断 show，或按配置）
        if (!kHiveNoAdsFakeReward) {
            // always block
        } else {
            if (strstr(table[i].cls, "Reward") && strstr(table[i].sel, "load")) {
                continue;
            }
        }
        BOOL ok = HNATryHook(table[i].cls, table[i].sel, table[i].meta);
        if (!ok) {
            // silent — class may not be loaded yet
        }
    }
}

#pragma mark - Bulk scan

static void HNAHookClassAdMethods(Class cls) {
    if (!cls) return;
    NSString *cname = NSStringFromClass(cls);
    if (!HNAClassNameLooksLikeAd(cname)) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (!HNASelectorLooksLikeAdControl(sel)) continue;
        // reward fake: skip load hooks
        if (kHiveNoAdsFakeReward && [cname containsString:@"Reward"] &&
            [NSStringFromSelector(sel) containsString:@"load"]) {
            continue;
        }
        HNAReplaceMethod(cls, sel, NO);
    }
    if (methods) free(methods);

    Class meta = object_getClass((id)cls);
    if (meta && meta != cls) {
        count = 0;
        methods = class_copyMethodList(meta, &count);
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            if (!HNASelectorLooksLikeAdControl(sel)) continue;
            HNAReplaceMethod(cls, sel, YES);
        }
        if (methods) free(methods);
    }
}

static void HNAScanAndHookAllAdClasses(void) {
    HNALog(@"scanning classes...");
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger matched = 0;
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (!HNAClassNameLooksLikeAd(name)) continue;
        HNAHookClassAdMethods(classes[i]);
        matched++;
    }
    if (classes) free(classes);
    HNALog(@"scanned %u classes, ad-like ~%lu", count, (unsigned long)matched);
}

#pragma mark - UIView / UIViewController swizzle

static void (*HNAOrig_didMoveToWindow)(id, SEL) = NULL;
static void (*HNAOrig_setHidden)(id, SEL, BOOL) = NULL;
static void (*HNAOrig_present)(id, SEL, id, BOOL, id) = NULL;

static void HNA_didMoveToWindow(UIView *self, SEL _cmd) {
    if (HNAOrig_didMoveToWindow) HNAOrig_didMoveToWindow(self, _cmd);
    if (!self.window) return;
    NSString *name = NSStringFromClass(object_getClass(self));
    if (HNAShouldForceHideViewName(name)) {
        HNALog(@"hide view %@", name);
        self.hidden = YES;
        self.alpha = 0;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        CGRect f = self.frame;
        if (f.size.height > 1) {
            f.size.height = 0;
            self.frame = f;
        }
    }
}

static void HNA_setHidden(UIView *self, SEL _cmd, BOOL hidden) {
    if (!hidden) {
        NSString *name = NSStringFromClass(object_getClass(self));
        if (HNAShouldForceHideViewName(name)) {
            HNALog(@"force hidden %@", name);
            if (HNAOrig_setHidden) HNAOrig_setHidden(self, _cmd, YES);
            return;
        }
    }
    if (HNAOrig_setHidden) HNAOrig_setHidden(self, _cmd, hidden);
}

static void HNA_present(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL flag, id completion) {
    if (vc) {
        NSString *name = NSStringFromClass(object_getClass(vc));
        BOOL block =
            [name containsString:@"SplashAd"] ||
            [name containsString:@"Interstitial"] ||
            ([name containsString:@"Reward"] && [name containsString:@"Ad"]) ||
            ([name containsString:@"WindMill"] && ([name containsString:@"Ad"] || [name containsString:@"Native"])) ||
            [name containsString:@"InsertAD"] ||
            [name containsString:@"DSPHomeAds"] ||
            [name containsString:@"CheckOutAlertInsertAD"] ||
            [name containsString:@"LifeServiceHomeAD"] ||
            ([name containsString:@"GDT"] && [name containsString:@"Ad"]) ||
            ([name containsString:@"CSJ"] && [name containsString:@"Ad"]) ||
            [name containsString:@"BUNative"] ||
            [name containsString:@"KSSplash"] ||
            [name containsString:@"KSInterstitial"];
        if (block) {
            HNALog(@"block present %@", name);
            if (completion) {
                void (^blk)(void) = completion;
                blk();
            }
            return;
        }
    }
    if (HNAOrig_present) HNAOrig_present(self, _cmd, vc, flag, completion);
}

static void HNASwizzleInstance(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (outOrig) *outOrig = old;
    method_setImplementation(m, newImp);
    HNALog(@"swizzle -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
}

static void HNAInstallUISwizzles(void) {
    HNASwizzleInstance([UIView class], @selector(didMoveToWindow), (IMP)HNA_didMoveToWindow, (IMP *)&HNAOrig_didMoveToWindow);
    HNASwizzleInstance([UIView class], @selector(setHidden:), (IMP)HNA_setHidden, (IMP *)&HNAOrig_setHidden);
    HNASwizzleInstance([UIViewController class],
                       @selector(presentViewController:animated:completion:),
                       (IMP)HNA_present,
                       (IMP *)&HNAOrig_present);
}

#pragma mark - Entry

static void HNAApplyAll(void) {
    HNAHookKnownSDK();
    HNAScanAndHookAllAdClasses();
}

__attribute__((constructor))
static void HiveNoAdsInit(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        HNALog(@"loaded in %@ (TrollFools dylib, no Substrate)", bid);

        // 只在丰巢里干活（TrollFools 一般只注入目标 App，双保险）
        if (bid.length && ![bid isEqualToString:@"com.fcbox.hiveconsumer"] &&
            ![bid containsString:@"fcbox"] && ![bid containsString:@"hiveconsumer"]) {
            // 仍允许：有些注入场景 bundle 未就绪
            HNALog(@"bundle %@ — still applying (TrollFools target assumed)", bid);
        }

        HNAInstallUISwizzles();

        // 立即 + 延迟（Swift/SDK 懒加载）
        HNAApplyAll();
        dispatch_async(dispatch_get_main_queue(), ^{
            HNAApplyAll();
            HNALog(@"main-queue hooks done");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HNAApplyAll();
            HNALog(@"+2s rescan done");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HNAApplyAll();
            HNALog(@"+6s rescan done");
        });
    }
}
