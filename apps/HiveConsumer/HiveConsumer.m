//
// HiveConsumer.dylib — 丰巢去广告 (TrollFools)
// Bundle: com.fcbox.hiveconsumer | 分析版本: 6.32.0
//
// 性能原则:
//   - 不扫全进程类表 (objc_copyClassList 很慢)
//   - 不 hook UIView.didMoveToWindow / setHidden (每个 View 都会走)
//   - 默认关闭日志; stub 热路径零 NSLog
//   - 只对已知 SDK/业务类做定点 method 替换 + 延迟一次轻量补 hook
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>

#pragma mark - Config

static const BOOL kFakeReward = NO;   // YES = 激励尝试空回调(实验)
static const BOOL kVerbose    = NO;   // YES = 调试日志 (会拖慢启动)

#define HCLog(fmt, ...) do { \
    if (kVerbose) NSLog(@"[HiveConsumer] " fmt, ##__VA_ARGS__); \
} while (0)

#pragma mark - Silent stubs (no logging)

static void stub_v0(id s, SEL c) {}
static void stub_v1(id s, SEL c, id a) {}
static void stub_v2(id s, SEL c, id a, id b) {}
static void stub_v3(id s, SEL c, id a, id b, id d) {}
static void stub_v4(id s, SEL c, id a, id b, id d, id e) {}
static BOOL stub_NO(id s, SEL c) { return NO; }
static BOOL stub_YES(id s, SEL c) { return YES; }
static id   stub_nil(id s, SEL c) { return nil; }
static id   stub_nil1(id s, SEL c, id a) { return nil; }

static IMP stubForEncoding(const char *type, unsigned argc, SEL sel) {
    if (!type) return NULL;
    char r = type[0];
    if (r == 'v') {
        if (argc <= 2) return (IMP)stub_v0;
        if (argc == 3) return (IMP)stub_v1;
        if (argc == 4) return (IMP)stub_v2;
        if (argc == 5) return (IMP)stub_v3;
        return (IMP)stub_v4;
    }
    if (r == 'B' || r == 'c') {
        // 仅 isReady / isAdValid 等返回 NO；不碰 isVip 等（避免误伤业务）
        return (IMP)stub_NO;
    }
    if (r == '@') {
        return (argc <= 2) ? (IMP)stub_nil : (IMP)stub_nil1;
    }
    return NULL;
}

static BOOL replaceMethod(Class cls, SEL sel, BOOL meta) {
    if (!cls || !sel) return NO;
    Method m = meta ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    unsigned n = method_getNumberOfArguments(m);
    IMP imp = stubForEncoding(enc, n, sel);
    if (!imp) return NO;
    IMP old = method_getImplementation(m);
    if (old == imp) return YES;
    method_setImplementation(m, imp);
    return YES;
}

static int hookSel(const char *cname, const char *sname, BOOL meta) {
    Class cls = objc_getClass(cname);
    if (!cls) return 0;
    SEL sel = sel_registerName(sname);
    return replaceMethod(cls, sel, meta) ? 1 : 0;
}

/// 对类上「名字像广告控制」的方法做替换；只遍历该类 method list，不扫全局
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
        if (!sn) continue;

        // 快速 C 字符串匹配，避免每次 NSString
        BOOL hit =
            strstr(sn, "loadAd") || strstr(sn, "LoadAd") || strstr(sn, "loadAD") ||
            strstr(sn, "showAd") || strstr(sn, "ShowAd") || strstr(sn, "showAD") ||
            strstr(sn, "showSplash") || strstr(sn, "loadSplash") ||
            strstr(sn, "autoShowAd") || strstr(sn, "showAdInWindow") ||
            strstr(sn, "showAdFromRoot") || strstr(sn, "showFromRootViewController") ||
            strstr(sn, "loadAdData") || strstr(sn, "_loadAdData") ||
            strstr(sn, "setupSDKWithAppId") ||
            strcmp(sn, "isReady") == 0 || strcmp(sn, "isAdValid") == 0 ||
            strstr(sn, "loadADWithPlacement") || strstr(sn, "loadAdWithPlacement");

        if (!hit) continue;

        // 激励: 默认连 load 也断; FakeReward 时放过 load
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
    int n = 0;
    n += hookAdSelectorsOnClass(cls, NO);
    n += hookAdSelectorsOnClass(cls, YES);
    return n;
}

#pragma mark - Known class table (no full runtime scan)

static const char *kKnownClasses[] = {
    // WindMill
    "WindMillAds",
    "WindMillSplashAd",
    "WindMillSplashAdManager",
    "WindMillIntersititialAd",   // SDK 原始拼写
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
    "WindAds",

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

    // AnyThink / ToBid 常见入口
    "ATAdManager",
    "ATSplash",
    "ATRewardedVideo",
    "ATInterstitial",
    "ATBanner",

    // 业务层 (Swift 运行时名: 模块+类 → _TtC12HiveConsumer...)
    // 同时尝试 demangled 短名 (部分工具/桥接会注册)
    "SplashAdManager",
    "FCSplashADSManager",
    "SplashAdLibHandler",
    "AdCenter",
    "AdsHandle",
    "AdsCNManager",
    "DSPAds",
    "OpenScrAdLibUBIX",
    "OpenScrAdLibToBid",
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

    // Swift mangled (HiveConsumer 模块长度 12)
    "_TtC12HiveConsumer15SplashAdManager",
    "_TtC12HiveConsumer18FCSplashADSManager",
    "_TtC12HiveConsumer18SplashAdLibHandler",
    "_TtC12HiveConsumer8AdCenter",
    "_TtC12HiveConsumer9AdsHandle",
    "_TtC12HiveConsumer12AdsCNManager",
    "_TtC12HiveConsumer6DSPAds",
    "_TtC12HiveConsumer16OpenScrAdLibUBIX",
    "_TtC12HiveConsumer17OpenScrAdLibToBid",
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
    NULL
};

static int applyKnownHooks(void) {
    int total = 0;
    for (int i = 0; kKnownClasses[i]; i++) {
        total += hookClassByName(kKnownClasses[i]);
    }
    // 额外显式保证 SDK 初始化被掐断
    total += hookSel("WindMillAds", "setupSDKWithAppId:sdkConfigures:", YES);
    total += hookSel("WindMillAds", "setupPrivacyServices", YES);
    return total;
}

#pragma mark - present 拦截 (轻量: 仅 VC present 路径)

static void (*orig_present)(id, SEL, id, BOOL, id) = NULL;

static BOOL nameLooksLikeAdVC(const char *n) {
    if (!n) return NO;
    if (strstr(n, "SplashAd")) return YES;
    if (strstr(n, "Interstitial")) return YES;
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
    Class cls = [UIViewController class];
    SEL sel = @selector(presentViewController:animated:completion:);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    orig_present = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)hooked_present);
}

#pragma mark - UIView 高度折叠: 仅对已知广告 View 子类 swizzle (不碰 UIView 根类)

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

/// 始终链式调用 UIView 原实现，避免误伤全局
static void hooked_didMove(UIView *self, SEL _cmd) {
    static void (*uiViewDidMove)(id, SEL) = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method root = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
        if (root) uiViewDidMove = (void *)method_getImplementation(root);
    });
    if (uiViewDidMove) uiViewDidMove(self, _cmd);
    // 只有挂到广告 View 子类上才会进这里
    if (self.window) hideIfNeeded(self);
}

static void swizzleDidMoveOnClass(const char *cname) {
    Class cls = objc_getClass(cname);
    if (!cls) return;
    if (![cls isSubclassOfClass:[UIView class]]) return;

    SEL sel = @selector(didMoveToWindow);
    Method root = class_getInstanceMethod([UIView class], sel);
    if (!root) return;
    const char *enc = method_getTypeEncoding(root);

    // 子类尚无自己的实现 → addMethod 只影响该子类
    if (!class_addMethod(cls, sel, (IMP)hooked_didMove, enc)) {
        // 已有实现 → 直接替换该类 method（不改 UIView）
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
    "WindMillBannerView",
    "WindMillNativeAdView",
    "GDTUnifiedNativeAdView",
    "CSJNativeExpressAdView",
    NULL
};

static void installViewHooks(void) {
    // orig_didMove 统一指向 UIView 原实现
    Method root = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
    if (root && !orig_didMove) orig_didMove = (void *)method_getImplementation(root);
    for (int i = 0; kAdViews[i]; i++) {
        swizzleDidMoveOnClass(kAdViews[i]);
    }
}

#pragma mark - Entry

static void applyAll(const char *tag) {
    int n = applyKnownHooks();
    HCLog(@"%s hooks=%d", tag, n);
}

__attribute__((constructor))
static void HiveConsumerDylibInit(void) {
    @autoreleasepool {
        // 极轻量: 构造期只装 present + 已加载的已知类
        installPresentHook();
        applyAll("ctor");
        installViewHooks();

        // 主线程下一圈: SDK +load 后类已齐，再补一次 (仍只扫白名单)
        dispatch_async(dispatch_get_main_queue(), ^{
            applyAll("main");
            installViewHooks();
        });

        // 仅 1 次延迟补 hook (Swift 懒加载)，后台队列，不堵 UI
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            applyAll("+1.5s");
            dispatch_async(dispatch_get_main_queue(), ^{
                installViewHooks();
            });
        });
    }
}
