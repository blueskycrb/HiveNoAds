//
// HiveNoAds — 丰巢 App (com.fcbox.hiveconsumer) 去广告
// 目标二进制: HiveConsumer 6.32.0 (arm64, decrypted)
//
// 广告栈 (静态分析结果):
//   业务层: SplashAdManager / FCSplashADSManager / AdCenter / AdsHandle /
//           OpenScrAdLib* / InterstScrAdLib* / NativeSplashAdView / DSPAds 等
//   聚合层: WindMill (Sigmob 风帆) + ToBid(TopOn) + AnyThink + UBiX
//   渠道层: 穿山甲 CSJ / 广点通 GDT / 快手 KSAd / 百度 / Sigmob ...
//   另: DCloud Uni 广告 DCUniSplashAd / DCUniInterstitialAd / DCUniRewardedAd
//
// 策略:
//   1) 阻断 WindMill / DCUni 等 ObjC SDK 的 load / show
//   2) 运行时扫描 *Ad* 类, hook 常见 loadAdData / showAd* / isReady
//   3) 隐藏业务层广告 UIView (开屏/Banner/信息流容器)
//   4) 激励视频: 默认阻止展示; 若业务强依赖可改 kHiveNoAdsFakeReward
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>

#pragma mark - Config

/// 1 = 激励视频也直接“假装看完发奖”(实验性, 可能无效或异常)
/// 0 = 仅阻止激励视频展示 (推荐; 看广告领奖功能会不可用)
static const BOOL kHiveNoAdsFakeReward = NO;

/// 详细日志 (Console / os_log, 过滤器: HiveNoAds)
static const BOOL kHiveNoAdsVerbose = YES;

#define HNALog(fmt, ...) do { \
    if (kHiveNoAdsVerbose) NSLog(@"[HiveNoAds] " fmt, ##__VA_ARGS__); \
} while (0)

#pragma mark - Helpers

static BOOL HNAClassNameLooksLikeAd(NSString *name) {
    if (name.length == 0) return NO;

    // Address / Adress 误伤极多 (SendAddress / WashAddress ...)
    if ([name containsString:@"Address"] || [name containsString:@"Adress"]) return NO;
    if ([name containsString:@"AddService"] || [name containsString:@"AddTime"] ||
        [name containsString:@"AddPhoto"] || [name containsString:@"AddParams"]) return NO;

    static NSArray<NSString *> *pos = nil;
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
    // 宽松: 含 Ads / Advert；或以 Ad 结尾且不是 Trade 等
    if ([name containsString:@"Ads"] || [name containsString:@"Advert"]) return YES;
    if ([name hasSuffix:@"Ad"] && ![name containsString:@"Trade"] && ![name containsString:@"Upload"]) {
        return YES;
    }
    return NO;
}

static BOOL HNASelectorLooksLikeAdControl(SEL sel) {
    if (!sel) return NO;
    NSString *s = NSStringFromSelector(sel);
    if (s.length == 0) return NO;

    static NSArray<NSString *> *keys = nil;
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
            @"isReady", @"isAdValid", @"isValid",
            @"startSplash", @"openSplash", @"playSplash",
            @"loadWithPlacement", @"loadAdWith", @"loadAdData",
            @"_loadAdData", @"loadFilter",
        ];
    });
    for (NSString *k in keys) {
        if ([s containsString:k]) return YES;
    }
    return NO;
}

static BOOL HNAViewClassShouldHide(NSString *name) {
    if (!HNAClassNameLooksLikeAd(name)) return NO;
    // 只藏 UI 容器, 不藏 Manager / Model / API
    if ([name containsString:@"Manager"] || [name containsString:@"Model"] ||
        [name containsString:@"Protocol"] || [name containsString:@"Delegate"] ||
        [name containsString:@"Request"] || [name containsString:@"Config"] ||
        [name containsString:@"Tracker"] || [name containsString:@"Monitor"] ||
        [name containsString:@"Adapter"] || [name containsString:@"Strategy"] ||
        [name containsString:@"Service"] && ![name containsString:@"AdView"]) {
        return NO;
    }
    // 明确 UI
    if ([name containsString:@"View"] || [name containsString:@"Cell"] ||
        [name containsString:@"Controller"] || [name containsString:@"Alert"] ||
        [name containsString:@"Banner"] || [name containsString:@"Window"] ||
        [name containsString:@"Button"] && [name containsString:@"AD"]) {
        return YES;
    }
    return NO;
}

#pragma mark - Generic IMP stubs

static void HNA_void_id(id self, SEL _cmd) {
    HNALog(@"nop %@[%@ %@]", @"-", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}

static void HNA_void_id_id(id self, SEL _cmd, id a) {
    HNALog(@"nop %@[%@ %@] arg=%@", @"-", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd), a);
}

static void HNA_void_id_id_id(id self, SEL _cmd, id a, id b) {
    HNALog(@"nop -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}

static void HNA_void_id_id_id_id(id self, SEL _cmd, id a, id b, id c) {
    HNALog(@"nop -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
}

static BOOL HNA_bool_false(id self, SEL _cmd) {
    HNALog(@"isReady/isValid => NO  -[%@ %@]", NSStringFromClass(object_getClass(self)), NSStringFromSelector(_cmd));
    return NO;
}

static BOOL HNA_bool_true(id self, SEL _cmd) {
    return YES;
}

static id HNA_id_nil(id self, SEL _cmd) {
    return nil;
}

static id HNA_id_nil_id(id self, SEL _cmd, id a) {
    return nil;
}

/// 按方法签名替换为安全 stub (void / BOOL / id 为主)
static void HNAHookMethodToStub(Class cls, SEL sel, BOOL isClassMethod) {
    if (!cls || !sel) return;
    Method m = isClassMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return;

    const char *type = method_getTypeEncoding(m);
    if (!type) return;

    IMP newImp = NULL;
    // 粗判返回值
    if (type[0] == 'v') {
        unsigned n = method_getNumberOfArguments(m); // self, _cmd, ...
        if (n <= 2) newImp = (IMP)HNA_void_id;
        else if (n == 3) newImp = (IMP)HNA_void_id_id;
        else if (n == 4) newImp = (IMP)HNA_void_id_id_id;
        else newImp = (IMP)HNA_void_id_id_id_id;
    } else if (type[0] == 'B' || type[0] == 'c') {
        // isReady / isAdValid -> NO; 其它 BOOL 也 NO
        NSString *name = NSStringFromSelector(sel);
        if ([name containsString:@"isReady"] || [name containsString:@"isAdValid"] ||
            [name containsString:@"isValid"] || [name containsString:@"canShow"] ||
            [name containsString:@"shouldShow"] || [name containsString:@"needShow"]) {
            newImp = (IMP)HNA_bool_false;
        } else if ([name containsString:@"isVip"] || [name containsString:@"adFree"] ||
                   [name containsString:@"isMember"] || [name containsString:@"hasVip"]) {
            newImp = (IMP)HNA_bool_true;
        } else {
            newImp = (IMP)HNA_bool_false;
        }
    } else if (type[0] == '@') {
        unsigned n = method_getNumberOfArguments(m);
        newImp = (n <= 2) ? (IMP)HNA_id_nil : (IMP)HNA_id_nil_id;
    } else {
        return; // 复杂返回值先不 hook
    }

    if (!newImp) return;

    IMP old = method_getImplementation(m);
    if (old == newImp) return;
    method_setImplementation(m, newImp);
    HNALog(@"hooked %c[%@ %@]", isClassMethod ? '+' : '-', NSStringFromClass(cls), NSStringFromSelector(sel));
}

#pragma mark - Runtime bulk hook

static void HNAHookClassAdMethods(Class cls) {
    if (!cls) return;
    NSString *cname = NSStringFromClass(cls);
    if (!HNAClassNameLooksLikeAd(cname)) return;

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        if (!HNASelectorLooksLikeAdControl(sel)) continue;
        HNAHookMethodToStub(cls, sel, NO);
    }
    if (methods) free(methods);

    // class methods
    Class meta = object_getClass((id)cls);
    if (meta && meta != cls) {
        count = 0;
        methods = class_copyMethodList(meta, &count);
        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            if (!HNASelectorLooksLikeAdControl(sel)) continue;
            HNAHookMethodToStub(cls, sel, YES);
        }
        if (methods) free(methods);
    }
}

static void HNAScanAndHookAllAdClasses(void) {
    HNALog(@"scanning classes...");
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger hooked = 0;
    for (unsigned int i = 0; i < count; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        if (!HNAClassNameLooksLikeAd(name)) continue;
        HNAHookClassAdMethods(classes[i]);
        hooked++;
    }
    if (classes) free(classes);
    HNALog(@"scanned %u classes, ad-like ~%lu", count, (unsigned long)hooked);
}

#pragma mark - Explicit WindMill hooks (Logos)

%hook WindMillAds
+ (void)setupSDKWithAppId:(id)appId sdkConfigures:(id)cfg {
    HNALog(@"+[WindMillAds setupSDKWithAppId:] blocked appId=%@", appId);
    // 直接不初始化, 从源头断广告
}
+ (void)setupPrivacyServices {
}
+ (void)initDclogAndTrackQueueService {
}
%end

%hook WindMillSplashAd
- (void)loadAdData {
    HNALog(@"-[WindMillSplashAd loadAdData] blocked");
}
- (void)_loadAdData:(id)arg {
    HNALog(@"-[WindMillSplashAd _loadAdData:] blocked");
}
- (void)showAdInWindow:(id)window {
    HNALog(@"-[WindMillSplashAd showAdInWindow:] blocked");
}
- (BOOL)isReady {
    return NO;
}
- (BOOL)isAdValid {
    return NO;
}
%end

%hook WindMillSplashAdManager
- (void)showAdInWindow:(id)window {
    HNALog(@"-[WindMillSplashAdManager showAdInWindow:] blocked");
}
- (void)autoShowAd {
    HNALog(@"-[WindMillSplashAdManager autoShowAd] blocked");
}
- (void)showSplashAdFromRootViewController:(id)vc adapter:(id)a nativeAds:(id)n {
    HNALog(@"-[WindMillSplashAdManager showSplashAdFromRootViewController:...] blocked");
}
%end

// SDK 类名拼写就是 Intersititial (少一个 t)
%hook WindMillIntersititialAd
- (void)loadAdData {
    HNALog(@"-[WindMillIntersititialAd loadAdData] blocked");
}
- (void)_loadAdData:(id)arg {
}
- (void)showAdFromRootViewController:(id)vc {
    HNALog(@"-[WindMillIntersititialAd showAdFromRootViewController:] blocked");
}
- (void)showAdFromRootViewController:(id)vc options:(id)opt {
    HNALog(@"-[WindMillIntersititialAd showAdFromRootViewController:options:] blocked");
}
- (BOOL)isReady { return NO; }
- (BOOL)isAdValid { return NO; }
%end

%hook WindMillInterstitialAdManager
- (void)showAdFromRootViewController:(id)vc options:(id)opt {
    HNALog(@"-[WindMillInterstitialAdManager showAdFromRootViewController:options:] blocked");
}
- (void)showAdFromRootViewController:(id)vc adapter:(id)a nativeAds:(id)n {
    HNALog(@"-[WindMillInterstitialAdManager showAdFromRootViewController:adapter:nativeAds:] blocked");
}
%end

%hook WindMillRewardVideoAd
- (void)loadAdData {
    if (!kHiveNoAdsFakeReward) {
        HNALog(@"-[WindMillRewardVideoAd loadAdData] blocked");
        return;
    }
    %orig;
}
- (void)_loadAdData:(id)arg {
    if (!kHiveNoAdsFakeReward) return;
    %orig;
}
- (void)showAdFromRootViewController:(id)vc {
    HNALog(@"-[WindMillRewardVideoAd showAdFromRootViewController:] blocked (fake=%d)", kHiveNoAdsFakeReward);
    if (kHiveNoAdsFakeReward) {
        // 尝试触发奖励回调 (不同版本 selector 可能不同, 失败则静默)
        if ([self respondsToSelector:@selector(onAdReward:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(onAdReward:), @{});
        }
        if ([self respondsToSelector:@selector(onAdDidClosed)]) {
            ((void (*)(id, SEL))objc_msgSend)(self, @selector(onAdDidClosed));
        }
    }
}
- (void)showAdFromRootViewController:(id)vc options:(id)opt {
    HNALog(@"-[WindMillRewardVideoAd showAdFromRootViewController:options:] blocked");
    if (kHiveNoAdsFakeReward) {
        if ([self respondsToSelector:@selector(onAdReward:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(onAdReward:), @{});
        }
        if ([self respondsToSelector:@selector(onAdDidClosed)]) {
            ((void (*)(id, SEL))objc_msgSend)(self, @selector(onAdDidClosed));
        }
    }
}
- (BOOL)isReady {
    return kHiveNoAdsFakeReward ? YES : NO;
}
- (BOOL)isAdValid {
    return kHiveNoAdsFakeReward ? YES : NO;
}
%end

%hook WindMillRewardVideoAdManager
- (void)showAdFromRootViewController:(id)vc options:(id)opt {
    HNALog(@"-[WindMillRewardVideoAdManager showAdFromRootViewController:options:] blocked");
}
- (void)showAdFromRootViewController:(id)vc adapter:(id)a nativeAds:(id)n {
    HNALog(@"-[WindMillRewardVideoAdManager showAdFromRootViewController:adapter:nativeAds:] blocked");
}
%end

%hook WindMillBannerView
- (void)loadAdData {
    HNALog(@"-[WindMillBannerView loadAdData] blocked");
}
- (void)_loadAdData:(id)arg {
}
- (BOOL)isReady { return NO; }
%end

%hook WindMillBannerAdManager
- (void)showAdFromRootViewController:(id)vc adapter:(id)a nativeAds:(id)n {
    HNALog(@"-[WindMillBannerAdManager showAdFromRootViewController:...] blocked");
}
- (void)restartRefreshTimer {
}
%end

%hook WindMillNativeAdsManager
- (void)loadAdData {
    HNALog(@"-[WindMillNativeAdsManager loadAdData] blocked");
}
- (id)initWithRequest:(id)req {
    HNALog(@"-[WindMillNativeAdsManager initWithRequest:] -> nil path (still create but no load)");
    return %orig;
}
%end

%hook WindAdManager
- (void)showAdFromRootViewController:(id)vc options:(id)opt {
    HNALog(@"-[WindAdManager showAdFromRootViewController:options:] blocked");
}
- (id)loadFilterAndReturnError {
    return nil;
}
%end

%hook WindSplashAdManager
- (id)loadFilterAndReturnError {
    return nil;
}
%end

#pragma mark - DCloud Uni Ads

%hook DCUniAdManager
%end

%hook DCUniSplashAd
- (void)loadAdData {
    HNALog(@"-[DCUniSplashAd loadAdData] blocked");
}
- (void)showAdInWindow:(id)w {
    HNALog(@"-[DCUniSplashAd showAdInWindow:] blocked");
}
- (void)showSplashAdInWindow:(id)w {
}
- (BOOL)isReady { return NO; }
%end

%hook DCUniInterstitialAd
- (void)loadAdData {
    HNALog(@"-[DCUniInterstitialAd loadAdData] blocked");
}
- (void)showAdFromRootViewController:(id)vc {
    HNALog(@"-[DCUniInterstitialAd showAdFromRootViewController:] blocked");
}
- (BOOL)isReady { return NO; }
%end

%hook DCUniRewardedAd
- (void)loadAdData {
    if (!kHiveNoAdsFakeReward) return;
    %orig;
}
- (void)showAdFromRootViewController:(id)vc {
    HNALog(@"-[DCUniRewardedAd showAdFromRootViewController:] blocked");
}
- (BOOL)isReady { return kHiveNoAdsFakeReward; }
%end

%hook DCBasicSplashAd
- (void)loadAdData {
    HNALog(@"-[DCBasicSplashAd loadAdData] blocked");
}
%end

%hook DCDcloudSplashAd
- (void)loadAdData {
    HNALog(@"-[DCDcloudSplashAd loadAdData] blocked");
}
%end

#pragma mark - Hide ad UIViews

%hook UIView
- (void)didMoveToWindow {
    %orig;
    if (!self.window) return;
    NSString *name = NSStringFromClass(object_getClass(self));
    // Swift 名: _TtC12HiveConsumer18NativeSplashAdView 等
    if ([name containsString:@"HiveConsumer"] || [name hasPrefix:@"_TtC"]) {
        if (HNAViewClassShouldHide(name) ||
            [name containsString:@"NativeSplashAdView"] ||
            [name containsString:@"SplashAdBottom"] ||
            [name containsString:@"CashDeskTakuAD"] ||
            [name containsString:@"CheckoutAdFeed"] ||
            [name containsString:@"BoxMobilePickAD"] ||
            [name containsString:@"SendOrderAdBanner"] ||
            [name containsString:@"WashSOAds"] ||
            [name containsString:@"DSPHomeAds"] ||
            [name containsString:@"LifeServiceHomeAD"] ||
            [name containsString:@"LSOrderPayAd"] ||
            [name containsString:@"CheckOutAlertInsertAD"] ||
            [name containsString:@"OpenScrAd"] ||
            [name containsString:@"InterstScrAd"]) {
            HNALog(@"hide view %@", name);
            self.hidden = YES;
            self.alpha = 0;
            self.userInteractionEnabled = NO;
            // 尽量塌陷高度
            self.clipsToBounds = YES;
            CGRect f = self.frame;
            if (f.size.height > 0) {
                f.size.height = 0;
                self.frame = f;
            }
        }
    } else if (HNAViewClassShouldHide(name)) {
        // SDK 自带广告 View
        if ([name containsString:@"WindMill"] || [name containsString:@"GDT"] ||
            [name containsString:@"CSJ"] || [name containsString:@"KSAd"] ||
            [name containsString:@"BUNative"] || [name containsString:@"BUSplash"] ||
            [name containsString:@"SplashAd"] || [name containsString:@"BannerAd"] ||
            [name containsString:@"NativeAdView"] || [name containsString:@"Reward"]) {
            HNALog(@"hide sdk view %@", name);
            self.hidden = YES;
            self.alpha = 0;
            self.userInteractionEnabled = NO;
        }
    }
}

- (void)setHidden:(BOOL)hidden {
    NSString *name = NSStringFromClass(object_getClass(self));
    if (!hidden && (HNAViewClassShouldHide(name) ||
        [name containsString:@"NativeSplashAdView"] ||
        [name containsString:@"WindMillBanner"] ||
        [name containsString:@"CashDeskTakuAD"] ||
        [name containsString:@"CheckoutAdFeed"] ||
        [name containsString:@"BoxMobilePickADBanner"] ||
        [name containsString:@"SendOrderAdBanner"] ||
        [name containsString:@"DSPHomeAds"])) {
        HNALog(@"force hidden %@", name);
        %orig(YES);
        return;
    }
    %orig(hidden);
}
%end

#pragma mark - Block common ad VC presentation (开屏/插屏 VC)

%hook UIViewController
- (void)presentViewController:(UIViewController *)vc animated:(BOOL)flag completion:(void (^)(void))completion {
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
            if (completion) completion();
            return;
        }
    }
    %orig;
}
%end

#pragma mark - Constructor

%ctor {
    @autoreleasepool {
        HNALog(@"loaded — bundle filter com.fcbox.hiveconsumer");
        // 等 runtime / +load 完成后再扫
        dispatch_async(dispatch_get_main_queue(), ^{
            HNAScanAndHookAllAdClasses();
            HNALog(@"ready");
        });
        // 二次扫描: 部分 Swift 类懒注册
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            HNAScanAndHookAllAdClasses();
            HNALog(@"rescan done");
        });
    }
}
