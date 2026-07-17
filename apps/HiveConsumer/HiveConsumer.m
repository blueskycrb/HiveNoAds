//
// HiveConsumer.dylib — 丰巢去广告 (TrollFools)
// Bundle: com.fcbox.hiveconsumer | 分析版本: 6.32.0 | iOS 16.5.1 闪退修复
//
// v4 原则（防崩）:
//   - 禁止 class_copyMethodList 自动替换（签名不可靠会崩）
//   - 禁止 hook UIApplication openURL（易误伤/崩）
//   - 禁止 hook 任意 isReady / 复杂参数方法
//   - 仅对已知「void + 对象参数」的 show/load 做定点替换
//   - present 拦截广告 VC；View 折叠只针对少数业务类
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static const BOOL kVerbose = NO;
#define HCLog(fmt, ...) do { if (kVerbose) NSLog(@"[HiveConsumer] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - Minimal stubs (arm64: self, _cmd, then id args)

static void stub_v0(id s, SEL c) { (void)s; (void)c; }
static void stub_v1(id s, SEL c, id a) { (void)s; (void)c; (void)a; }
static void stub_v2(id s, SEL c, id a, id b) { (void)s; (void)c; (void)a; (void)b; }
static void stub_v3(id s, SEL c, id a, id b, id d) { (void)s; (void)c; (void)a; (void)b; (void)d; }
static void stub_v4(id s, SEL c, id a, id b, id d, id e) {
    (void)s; (void)c; (void)a; (void)b; (void)d; (void)e;
}
static BOOL stub_NO(id s, SEL c) { (void)s; (void)c; return NO; }

/// 仅当：返回 void/BOOL，参数个数匹配，且 type encoding 里参数全是指针类 (@ : ^ # *) 时才 hook
static BOOL canSafelyStub(Method m, IMP *outImp) {
    if (!m || !outImp) return NO;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || !enc[0]) return NO;

    char ret = enc[0];
    if (ret != 'v' && ret != 'B' && ret != 'c') return NO;

    unsigned argc = method_getNumberOfArguments(m); // includes self,_cmd
    if (argc < 2 || argc > 6) return NO; // 最多 4 个业务参数

    // 解析每个参数类型（跳过 offsets）
    // 格式大致: v24@0:8@16@24
    const char *p = enc;
    // skip return type
    if (*p == 'v' || *p == 'B' || *p == 'c' || *p == '@' || *p == 'Q' || *p == 'q' ||
        *p == 'i' || *p == 'I' || *p == 'l' || *p == 'L' || *p == 's' || *p == 'S' ||
        *p == 'C' || *p == '*' || *p == '#' || *p == ':') {
        p++;
    } else if (*p == '^') {
        p++;
        if (*p) p++;
    } else {
        return NO;
    }
    while (*p >= '0' && *p <= '9') p++;

    // 逐个参数
    for (unsigned i = 0; i < argc; i++) {
        if (!*p) return NO;
        char t = *p;
        // 允许 @ : # * ^@ 以及 block @?
        if (t == '@') {
            p++;
            if (*p == '?' || *p == '"') {
                // @"NSString" or @?
                if (*p == '"') {
                    p++;
                    while (*p && *p != '"') p++;
                    if (*p == '"') p++;
                } else {
                    p++; // ?
                }
            }
        } else if (t == ':' || t == '#' || t == '*') {
            p++;
        } else if (t == '^') {
            p++;
            if (*p == '@' || *p == 'v' || *p == '*' || *p == '{') {
                if (*p == '{') {
                    // 指针指向 struct —— 仍当指针，寄存器上传 OK
                    int depth = 0;
                    do {
                        if (*p == '{') depth++;
                        else if (*p == '}') depth--;
                        p++;
                    } while (*p && depth > 0);
                } else {
                    p++;
                }
            }
        } else {
            // q i d f { 等值类型 —— 不 hook
            return NO;
        }
        while (*p >= '0' && *p <= '9') p++;
    }

    if (ret == 'B' || ret == 'c') {
        if (argc != 2) return NO;
        *outImp = (IMP)stub_NO;
        return YES;
    }
    // void
    switch (argc) {
        case 2: *outImp = (IMP)stub_v0; return YES;
        case 3: *outImp = (IMP)stub_v1; return YES;
        case 4: *outImp = (IMP)stub_v2; return YES;
        case 5: *outImp = (IMP)stub_v3; return YES;
        case 6: *outImp = (IMP)stub_v4; return YES;
        default: return NO;
    }
}

static BOOL hookExact(const char *cname, const char *sname, BOOL meta) {
    Class cls = objc_getClass(cname);
    if (!cls) return NO;
    Class target = meta ? object_getClass((id)cls) : cls;
    if (!target) return NO;
    SEL sel = sel_registerName(sname);

    // 只改「本类 method list」里的实现。
    // class_getInstanceMethod 会落到父类，method_setImplementation 会污染父类 → 全局闪退。
    Method own = NULL;
    unsigned int count = 0;
    Method *list = class_copyMethodList(target, &count);
    for (unsigned int i = 0; list && i < count; i++) {
        if (method_getName(list[i]) == sel) {
            own = list[i];
            break;
        }
    }
    free(list);
    if (!own) return NO;

    IMP stub = NULL;
    if (!canSafelyStub(own, &stub) || !stub) {
        HCLog(@"skip unsafe %c[%s %s]", meta ? '+' : '-', cname, sname);
        return NO;
    }
    if (method_getImplementation(own) != stub) {
        method_setImplementation(own, stub);
    }
    return YES;
}

#pragma mark - Exact ad control hooks only

static int applyExactHooks(void) {
    int n = 0;
    const struct { const char *cls; const char *sel; BOOL meta; } table[] = {
        // WindMill 初始化 / 开屏 / 插屏
        { "WindMillAds", "setupSDKWithAppId:sdkConfigures:", YES },
        { "WindMillAds", "setupPrivacyServices", YES },
        { "WindMillSplashAd", "showAdInWindow:", NO },
        { "WindMillSplashAdManager", "showAdInWindow:", NO },
        { "WindMillSplashAdManager", "autoShowAd", NO },
        { "WindMillSplashAdManager", "showSplashAdFromRootViewController:adapter:nativeAds:", NO },
        { "WindMillIntersititialAd", "showAdFromRootViewController:", NO },
        { "WindMillIntersititialAd", "loadAdData", NO },
        { "WindMillInterstitialAd", "showAdFromRootViewController:", NO },
        { "WindMillInterstitialAd", "loadAdData", NO },
        { "WindMillRewardVideoAd", "loadAdData", NO },
        { "WindMillRewardVideoAd", "showAdFromRootViewController:", NO },
        { "WindMillBannerView", "loadAdData", NO },
        { "WindMillNativeAdsManager", "loadAdData", NO },
        { "WindSplashAdManager", "loadFilterAndReturnError", NO },

        // UBiX 开屏
        { "UbiXMSplashAdManager", "loadSplash:withLifeModel:", NO },

        // 业务开屏 / 插屏（ObjC 名；Swift 短名若桥接可见）
        { "SplashAdManager", "showAdInWindow:", NO },
        { "SplashAdManager", "loadAdData", NO },
        { "FCSplashADSManager", "showAdInWindow:", NO },
        { "FCSplashADSManager", "loadAdData", NO },
        { "SplashAdLibHandler", "showAdInWindow:", NO },
        { "OpenScrAdLibUBIX", "loadAdData", NO },
        { "OpenScrAdLibToBid", "loadAdData", NO },
        { "OpenScrLibNative", "loadAdData", NO },
        { "InterstScrAdLibTaku", "loadAdData", NO },
        { "InterstScrAdLibTaku", "showAd", NO },
        { "InterstScrAdLibUBIX", "loadAdData", NO },
        { "InterstScrAdLibUBIX", "showAd", NO },
        { "AdsCNManager", "loadAdData", NO },
        { "AdsHandle", "loadAdData", NO },
        { "AdCenter", "loadAdData", NO },
        { "DSPAds", "loadAdData", NO },
        { "HomeConfigUbixHandle", "loadAdData", NO },

        // Swift mangled 同名选择子
        { "_TtC12HiveConsumer15SplashAdManager", "showAdInWindow:", NO },
        { "_TtC12HiveConsumer15SplashAdManager", "loadAdData", NO },
        { "_TtC12HiveConsumer18FCSplashADSManager", "showAdInWindow:", NO },
        { "_TtC12HiveConsumer18SplashAdLibHandler", "loadAdData", NO },
        { "_TtC12HiveConsumer16OpenScrAdLibUBIX", "loadAdData", NO },
        { "_TtC12HiveConsumer17OpenScrAdLibToBid", "loadAdData", NO },
        { "_TtC12HiveConsumer16OpenScrLibNative", "loadAdData", NO },
        { "_TtC12HiveConsumer19InterstScrAdLibTaku", "loadAdData", NO },
        { "_TtC12HiveConsumer19InterstScrAdLibUBIX", "loadAdData", NO },
        { "_TtC12HiveConsumer12AdsCNManager", "loadAdData", NO },
        { "_TtC12HiveConsumer9AdsHandle", "loadAdData", NO },
        { "_TtC12HiveConsumer8AdCenter", "loadAdData", NO },
        { "_TtC12HiveConsumer6DSPAds", "loadAdData", NO },
        { "_TtC12HiveConsumer20HomeConfigUbixHandle", "loadAdData", NO },

        // AnyThink 常见入口
        { "ATAdManager", "loadADWithPlacementID:extra:delegate:", NO },
        { "ATSplash", "loadADWithPlacementID:extra:delegate:", NO },

        { NULL, NULL, NO }
    };

    for (int i = 0; table[i].cls; i++) {
        if (hookExact(table[i].cls, table[i].sel, table[i].meta)) n++;
    }
    return n;
}

#pragma mark - present 拦截

static void (*orig_present)(id, SEL, id, BOOL, id) = NULL;

static BOOL nameLooksLikeAdVC(const char *n) {
    if (!n) return NO;
    if (strstr(n, "SplashAd")) return YES;
    if (strstr(n, "WindMillSplash") || strstr(n, "WindSplash")) return YES;
    if ((strstr(n, "UBiX") || strstr(n, "UbiX")) && strstr(n, "Splash")) return YES;
    if (strstr(n, "Interstitial") || strstr(n, "Intersititial")) return YES;
    if (strstr(n, "InsertAD")) return YES;
    if (strstr(n, "DSPHomeAds")) return YES;
    if (strstr(n, "LifeServiceHomeAD")) return YES;
    if (strstr(n, "SMStoreProduct") || strstr(n, "SKStoreProduct")) return YES;
    if (strstr(n, "DCUniSplash") || strstr(n, "DCBasicSplash") || strstr(n, "DCDcloudSplash")) return YES;
    if (strstr(n, "GDTSplash") || strstr(n, "BUSplash") || strstr(n, "CSJSplash") || strstr(n, "KSSplash")) return YES;
    if (strstr(n, "Reward") && strstr(n, "Ad") && strstr(n, "Controller")) return YES;
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

#pragma mark - 少量广告 View 折叠（不碰 UIView 根类）

static void hideIfNeeded(UIView *v) {
    v.hidden = YES;
    v.alpha = 0;
    v.userInteractionEnabled = NO;
}

static void hooked_didMove(UIView *self, SEL _cmd) {
    static void (*rootIMP)(id, SEL) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method root = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
        if (root) rootIMP = (void *)method_getImplementation(root);
    });
    if (rootIMP) rootIMP(self, _cmd);
    if (self.window) hideIfNeeded(self);
}

static void swizzleDidMove(const char *cname) {
    Class cls = objc_getClass(cname);
    if (!cls) return;
    BOOL isView = NO;
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (c == [UIView class]) { isView = YES; break; }
    }
    if (!isView) return;

    SEL sel = @selector(didMoveToWindow);
    Method root = class_getInstanceMethod([UIView class], sel);
    if (!root) return;
    const char *enc = method_getTypeEncoding(root);

    // 只用 class_addMethod：若子类没有自己的实现则添加；
    // 绝不用 method_setImplementation(class_getInstanceMethod)——那会改到 UIView 父类实现，全局崩。
    if (!class_addMethod(cls, sel, (IMP)hooked_didMove, enc)) {
        // 子类已有自己的实现：只替换「本类 method list」里的
        unsigned int count = 0;
        Method *list = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; list && i < count; i++) {
            if (method_getName(list[i]) == sel) {
                if (method_getImplementation(list[i]) != (IMP)hooked_didMove) {
                    method_setImplementation(list[i], (IMP)hooked_didMove);
                }
                break;
            }
        }
        free(list);
    }
}

static void installViewHooks(void) {
    static const char *views[] = {
        "NativeSplashAdView",
        "_TtC12HiveConsumer18NativeSplashAdView",
        "SplashAdBottomView",
        "_TtC12HiveConsumer18SplashAdBottomView",
        "DSPHomeAdsAlertView",
        "_TtC12HiveConsumer19DSPHomeAdsAlertView",
        "LifeServiceHomeADPopAlertView",
        "_TtC12HiveConsumer29LifeServiceHomeADPopAlertView",
        "WindMillBannerView",
        "WindMillNativeAdView",
        "WindSplashAdView",
        NULL
    };
    for (int i = 0; views[i]; i++) swizzleDidMove(views[i]);
}

#pragma mark - Tab：隐藏洗衣/会员（不删 VC）

static void (*orig_tabLayout)(id, SEL) = NULL;
static char kTabKey;

static NSArray<UIView *> *tabButtons(UITabBar *bar) {
    NSArray *saved = objc_getAssociatedObject(bar, &kTabKey);
    if ([saved isKindOfClass:[NSArray class]] && saved.count == 5) {
        BOOL ok = YES;
        for (UIView *v in saved) {
            if (![v isKindOfClass:[UIView class]] || v.superview != bar) { ok = NO; break; }
        }
        if (ok) return saved;
    }

    NSMutableArray *arr = [NSMutableArray array];
    for (UIView *v in bar.subviews) {
        const char *n = class_getName(object_getClass(v));
        if (n && strstr(n, "MainTabBarItemContentView")) [arr addObject:v];
    }
    if (arr.count != 5) {
        [arr removeAllObjects];
        for (UIView *v in bar.subviews) {
            const char *n = class_getName(object_getClass(v));
            if (n && strcmp(n, "UITabBarButton") == 0) [arr addObject:v];
        }
    }
    if (arr.count != 5) return nil;

    [arr sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ax = a.frame.origin.x, bx = b.frame.origin.x;
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    objc_setAssociatedObject(bar, &kTabKey, arr, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return arr;
}

static void layoutTabs(UITabBar *bar) {
    if (!bar) return;
    NSArray<UIView *> *btns = tabButtons(bar);
    if (btns.count != 5) return;
    CGFloat w = bar.bounds.size.width / 3.0;
    if (w < 1) return;
    NSUInteger vis = 0;
    for (NSUInteger i = 0; i < 5; i++) {
        UIView *b = btns[i];
        BOOL hide = (i == 1 || i == 2);
        b.hidden = hide;
        b.userInteractionEnabled = !hide;
        if (hide) continue;
        CGRect f = b.frame;
        f.origin.x = w * vis;
        f.size.width = w;
        b.frame = f;
        vis++;
    }
}

static void hooked_tabLayout(UITabBarController *self, SEL cmd) {
    if (orig_tabLayout) orig_tabLayout(self, cmd);
    @try { layoutTabs(self.tabBar); } @catch (__unused NSException *e) {}
}

static void installTabHooks(void) {
    Class cls = objc_getClass("MainTabBarController");
    if (!cls) cls = objc_getClass("_TtC12HiveConsumer20MainTabBarController");
    if (!cls) return;

    BOOL isTab = NO;
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (c == [UITabBarController class]) { isTab = YES; break; }
    }
    if (!isTab) return;

    SEL sel = @selector(viewDidLayoutSubviews);
    Method root = class_getInstanceMethod([UITabBarController class], sel);
    if (!root) root = class_getInstanceMethod([UIViewController class], sel);
    if (!root) return;
    const char *enc = method_getTypeEncoding(root);

    // 先看本类是否已有实现
    Method own = NULL;
    unsigned int count = 0;
    Method *list = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; list && i < count; i++) {
        if (method_getName(list[i]) == sel) { own = list[i]; break; }
    }

    if (own) {
        IMP cur = method_getImplementation(own);
        if (cur == (IMP)hooked_tabLayout) { free(list); return; }
        orig_tabLayout = (void *)cur;
        method_setImplementation(own, (IMP)hooked_tabLayout);
    } else {
        // 本类没有：add 一层，原实现走父类（UIViewController 默认）
        orig_tabLayout = (void *)method_getImplementation(root);
        class_addMethod(cls, sel, (IMP)hooked_tabLayout, enc);
    }
    free(list);
}

#pragma mark - Entry

static void applyAll(const char *tag) {
    int n = 0;
    @try {
        n = applyExactHooks();
        installViewHooks();
        installTabHooks();
    } @catch (NSException *e) {
        NSLog(@"[HiveConsumer] %@ exception %@", @(tag), e);
        return;
    }
    HCLog(@"%s hooks=%d", tag, n);
}

static void onForeground(void) {
    applyAll("fg");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ applyAll("fg+0.5"); });
}

__attribute__((constructor))
static void HiveConsumerDylibInit(void) {
    @autoreleasepool {
        // 始终打一行，确认 dylib 已加载（非 verbose）
        NSLog(@"[HiveConsumer] dylib loaded (v4 safe)");

        // present 尽量早
        @try { installPresentHook(); } @catch (__unused NSException *e) {}

        // 其余全部主线程，UIKit 就绪后
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                applyAll("main");
                [[NSNotificationCenter defaultCenter]
                 addObserverForName:UIApplicationWillEnterForegroundNotification
                 object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(__unused NSNotification *n) { onForeground(); }];
            } @catch (NSException *e) {
                NSLog(@"[HiveConsumer] main init exception %@", e);
            }
        });

        // 懒加载类补 hook（主线程，避免后台改 method 竞态）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyAll("+2s"); });
    }
}
