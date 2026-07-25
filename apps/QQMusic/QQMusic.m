//
// QQMusic.dylib — QQ音乐去广告 (TrollFools)
// Bundle: com.tencent.QQMusic | 可执行名: QQMusic | 分析版本: 20.6.0 (21302)
//
// 广告栈:
//   开屏: QMTMEAdSplash / QMGDTSplash / FlashWindow / FlashScreenManager / TMEAdSplashAd
//   Banner/挂件: KSBannerAdManager / QMTMEAdPendantManager / BeltAd / SongFrontAd
//   激励/免模: QMTMERewardAd / QMGDTRewardAd / QMFreeModeManager (默认拦 show)
//   SDK: TMEAd* / GDT*
//
// v4 原则（防崩）:
//   - 仅定点 exact hook（本类 method list）
//   - 仅 void/BOOL + 指针参数
//   - 不 hook openURL / 不扫全类 / 不改 UIView 根类
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static const BOOL kVerbose = NO;
// YES = 保留激励视频 load（看广告领免费听可开）；默认全拦
static const BOOL kKeepReward = NO;

#define QMLog(fmt, ...) do { if (kVerbose) NSLog(@"[QQMusic] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - Minimal stubs

static void stub_v0(id s, SEL c) { (void)s; (void)c; }
static void stub_v1(id s, SEL c, id a) { (void)s; (void)c; (void)a; }
static void stub_v2(id s, SEL c, id a, id b) { (void)s; (void)c; (void)a; (void)b; }
static void stub_v3(id s, SEL c, id a, id b, id d) { (void)s; (void)c; (void)a; (void)b; (void)d; }
static void stub_v4(id s, SEL c, id a, id b, id d, id e) {
    (void)s; (void)c; (void)a; (void)b; (void)d; (void)e;
}
static BOOL stub_NO(id s, SEL c) { (void)s; (void)c; return NO; }
static BOOL stub_NO1(id s, SEL c, id a) { (void)s; (void)c; (void)a; return NO; }
static id   stub_nil0(id s, SEL c) { (void)s; (void)c; return nil; }
static id   stub_nil1(id s, SEL c, id a) { (void)s; (void)c; (void)a; return nil; }
static id   stub_nil2(id s, SEL c, id a, id b) { (void)s; (void)c; (void)a; (void)b; return nil; }
static id   stub_nil3(id s, SEL c, id a, id b, id d) {
    (void)s; (void)c; (void)a; (void)b; (void)d; return nil;
}

/// 仅当：返回 void/BOOL/id，参数个数匹配，且 type encoding 里参数全是指针类 (@ : ^ # *) 时才 hook
static BOOL canSafelyStub(Method m, IMP *outImp) {
    if (!m || !outImp) return NO;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || !enc[0]) return NO;

    char ret = enc[0];
    if (ret != 'v' && ret != 'B' && ret != 'c' && ret != '@') return NO;

    unsigned argc = method_getNumberOfArguments(m);
    if (argc < 2 || argc > 6) return NO;

    const char *p = enc;
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

    for (unsigned i = 0; i < argc; i++) {
        if (!*p) return NO;
        char t = *p;
        if (t == '@') {
            p++;
            if (*p == '?' || *p == '"') {
                if (*p == '"') {
                    p++;
                    while (*p && *p != '"') p++;
                    if (*p == '"') p++;
                } else {
                    p++;
                }
            }
        } else if (t == ':' || t == '#' || t == '*') {
            p++;
        } else if (t == '^') {
            p++;
            if (*p == '@' || *p == 'v' || *p == '*' || *p == '{') {
                if (*p == '{') {
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
            return NO;
        }
        while (*p >= '0' && *p <= '9') p++;
    }

    if (ret == 'B' || ret == 'c') {
        if (argc == 2) { *outImp = (IMP)stub_NO; return YES; }
        if (argc == 3) { *outImp = (IMP)stub_NO1; return YES; }
        return NO;
    }
    if (ret == '@') {
        switch (argc) {
            case 2: *outImp = (IMP)stub_nil0; return YES;
            case 3: *outImp = (IMP)stub_nil1; return YES;
            case 4: *outImp = (IMP)stub_nil2; return YES;
            case 5: *outImp = (IMP)stub_nil3; return YES;
            default: return NO;
        }
    }
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
        QMLog(@"skip unsafe %c[%s %s]", meta ? '+' : '-', cname, sname);
        return NO;
    }
    if (method_getImplementation(own) != stub) {
        method_setImplementation(own, stub);
    }
    return YES;
}

#pragma mark - Exact ad control hooks

static int applyExactHooks(void) {
    int n = 0;
    const struct { const char *cls; const char *sel; BOOL meta; } table[] = {
        // —— TME 开屏 ——
        { "QMTMEAdSplash", "showSplashWithDelegate:", NO },
        { "QMTMEAdSplash", "_showSplashWithOrder:", NO },
        { "QMTMEAdSplash", "_delayShowSplash", NO },
        { "QMTMEAdSplash", "_showSplashInPrePick", NO },
        { "QMTMEAdSplash", "_preloadSplashWithLaunchingType:completion:", NO },
        { "QMTMEAdSplash", "preLoadColdSplash:", YES },
        { "QMTMEAdSplash", "checkCanShowSplashInPerceived:", NO },
        { "QMTMEAdSplash", "finishSplashByPerceivedTimeOut", NO },
        { "QMTMEAdSplash", "showPlayerSplashV2WithOrder:withCustomUI:", NO },
        { "QMTMEAdSplash", "addSongPageSplashLastFrame", NO },
        { "QMTMEAdSplash", "openFreeModeIfNeed", NO },

        // —— GDT 开屏 ——
        { "QMGDTSplash", "showSplashWithDelegate:", NO },
        { "QMGDTSplash", "_showSplashWithOrder:", NO },
        { "QMGDTSplash", "_delayShowSplash", NO },
        { "QMGDTSplash", "_preloadSplashWithLaunchingType:", NO },
        { "QMGDTSplash", "handleTimeout", NO },
        { "QMGDTSplash", "applicationWillEnterForeground", NO },
        { "QMGDTSplash", "applicationDidBecomeActive", NO },

        // —— FlashWindow 业务开屏壳 ——
        { "FlashWindow", "showSDKSplash", NO },
        { "FlashWindow", "showSplashV2", NO },
        { "FlashWindow", "_showSDKSplashSafe", NO },
        { "FlashWindow", "_showSplashV2:", NO },
        { "FlashWindow", "_initSDKSplashSafe", NO },
        { "FlashWindow", "splashSDKWillShow:", NO },
        { "FlashWindow", "splashSDKWillPick", NO },
        { "FlashWindow", "addSplashControlViewsWithItem:rootView:", NO },

        { "FlashScreenManager", "_preloadHotSplashIfNeed", NO },
        { "FlashScreenManager", "splashWillShow:", NO },
        { "FlashScreenManager", "splashSkipShow:", NO },
        { "FlashScreenManager", "getSplashItemWithOptions:launchingType:splashCanPick:", NO },
        { "FlashScreenManager", "getSplashV2ItemWithOptions:launchingType:splashCanPick:", NO },

        // —— 预加载服务 ——
        { "QMTMEAdSplashPrePickManager", "prePickSplash", NO },
        { "QMTMEAdSplashPrePickManager", "prePickSplashV2", NO },
        { "TADSplashPreloadAdServiceImpl", "loadAdData", NO },
        { "TGGDTPreloadSplashAdService", "loadAdData", NO },
        { "QMSplashAdDataManager", "fetchPosConfigs", NO },
        { "QMSplashAdDataManager", "handleUniConfig:placement:", NO },
        { "QMSplashPlayerAdResManager", "preDownloadAdWithSongId:skinId:", NO },

        // —— Banner ——
        { "KSBannerAdManager", "loadAd", NO },
        { "KSBannerAdManager", "loadAdWithChannelType:", NO },
        { "KSBannerAdManager", "loadAdWithCheckCache", NO },
        { "KSBannerAdManager", "loadAdWithPoint", NO },
        { "KSBannerAdManager", "loadComplexAdWithType:", NO },
        { "QMTMEBannerAdDataManager", "loadBannerAdData", NO },
        { "ChannelRootViewController_V4", "loadBannerAdData", NO },
        { "ChannelRootViewController_V4", "createTableHeaderViewV3BannerAd", NO },
        { "FolderSongsTabVC", "loadOmgAdBannerData", NO },
        { "QMMyMusicV3TableViewSectionDataSourceTMEAdBanner", "loadAdData:", NO },
        { "QMMyMusicV3TableViewSectionDataSourceTMEAdBanner", "preloadAdDataObjects", NO },
        { "QMMyMusicV3TableViewSectionDataSourceAdBanner", "showAdBannerIfNeeded", NO },
        { "QMSearchHotItemTMEAdBannerViewModel", "preloadAdDataObjects", NO },

        // —— 挂件 Pendant ——
        { "QMTMEAdPendantManager", "loadPendantAd", NO },
        { "QMTMEAdPendantManager", "startAdPointService", NO },
        { "QMTMEAdPendantManager", "tryRemovePendantAdView", NO },

        // —— 推荐/我的 腰封 Belt ——
        { "QMRecommendRootViewController", "insertBeltAdData", NO },
        { "QMRecommendRootViewController", "insertRecommendBeltAdDataIfNeed", NO },
        { "QMRecommendRootViewController", "insertRecommendBeltAdDataToGroupTableArray:", NO },
        { "QMMyMusicV3TableViewSectionDataSourceRecommend", "showMyMusicBeltAdIfNeed", NO },
        { "QMMyMusicV3TableViewSectionDataSourceRecommend", "insertMyMusicBeltAdWithDataObject:", NO },
        { "LongTrackRootViewController", "loadLongTrackBeltAdIfNeed", NO },
        { "LongTrackRootViewController", "insertLongTrackBeltAd", NO },
        { "QMLongTrackChannelVC", "loadLongTrackBeltAdV2IfNeed", NO },
        { "QMLongTrackChannelVC", "insertLongTrackBeltAd", NO },

        // —— 播放页贴片 / 歌前广告 ——
        { "QMPlayingSongPage", "showSongFrontAdIfNeed", NO },
        { "QMPlayingSongPage", "canShowSongFrontAd", NO },
        { "QMSongPageAdManager", "songPageAdExpose", NO },
        { "QMSongPageAdManagerV2", "preloadAdConfigAndDataWithSongInfo:themePlayer:", NO },
        { "QMSongPageAdManagerV2", "loadAdDisplayCgiWithSongInfo:complete:", NO },
        { "QMSongPageAdManagerV2", "enableRequestAd", NO },
        { "QMSongPageAdNativeRewardView", "loadAd", NO },
        { "QMSongPageAdView", "setupWithAdDataObject:", NO },
        { "QMSongFrontAdView", "setupWithAdDataObject:", NO },
        { "QMTMEAdDataManager", "preloadAdDataObjects", NO },
        { "QMTMENativeAdDataManager", "preloadAdDataObjects", NO },
        { "QMAIFolderSponsorAdManager", "preloadAdDataObjects", NO },
        { "QMListSponsorAdManager", "preloadAdDataObjects", NO },
        { "QMPersonalFolderAdManager", "preloadAdDataObjects", NO },

        // —— 激励视频（默认拦；kKeepReward 时跳过 load）——
        { "QMTMERewardAd", "loadVideoAd", NO },
        { "QMTMERewardAd", "showVideoAdFromVC:", NO },
        { "QMTMERewardAd", "showVideoAdFromNavPush", NO },
        { "QMGDTRewardAd", "loadVideoAd", NO },
        { "QMGDTRewardAd", "showVideoAdFromVC:", NO },
        { "KSRewardAdManager", "preloadRewardAd:", NO },
        { "KSGiftPannelAdManager", "showRewardAd", NO },
        { "KSGiftPannelAdManager", "requestRewardAdDataWithMask:completeBlock:", NO },
        { "QMRewardAdViewController", "showWithPlacement:entranceType:rewardAd:context:usePushVC:showCallback:eventCallback:", YES },

        // —— 免模广告入口（拦广告 load，不拦业务开关）——
        { "QMFreeModeManager", "loadAdDataWithPlacement:entranceType:onlyRewardCache:", NO },
        { "QMLongTrackFreeModeManager", "loadAdDataWithEntranceType:", NO },

        // —— CPD 绿钻/歌手页广告 ——
        { "CPDAdManager", "getNextGreenDiamondADItemToShow:filePath:", NO },
        { "CPDAdManager", "shouldSongShowSingerAd:", NO },
        { "CPDAdManager", "didLoadIconAdConfig:resultConfig:", NO },
        { "CPDAdManager", "didLoadSingerAdConfig:resultConfig:", NO },

        // —— TME / GDT SDK 层 ——
        { "TMEAdSplashAd", "loadAdData", NO },
        { "TMEAdSplashAd", "showAd", NO },
        { "TMEAdInterstitialAd", "loadAdData", NO },
        { "TMEAdInterstitialAd", "showAd", NO },
        { "TMEAdRewardedVideoAd", "loadAdData", NO },
        { "TMEAdRewardedVideoAd", "showAdFromRootViewController:", NO },
        { "TMEAdNative", "loadAdData", NO },
        { "GDTSplashAd", "loadAd", NO },
        { "GDTSplashAd", "showAdInWindow:withBottomView:", NO },
        { "GDTSplashAd", "showAdInWindow:withBottomView:skipView:", NO },
        { "GDTUnifiedInterstitialAd", "loadAd", NO },
        { "GDTUnifiedInterstitialAd", "presentAdFromRootViewController:", NO },
        { "GDTRewardVideoAd", "loadAd", NO },
        { "GDTRewardVideoAd", "showAdFromRootViewController:", NO },

        { NULL, NULL, NO }
    };

    for (int i = 0; table[i].cls; i++) {
        if (kKeepReward) {
            const char *s = table[i].sel;
            // 保留激励 load，仍拦 show
            if ((strstr(table[i].cls, "Reward") || strstr(s, "Reward") || strstr(s, "reward")) &&
                (strstr(s, "load") || strstr(s, "Load") || strstr(s, "preload") || strstr(s, "Preload"))) {
                continue;
            }
        }
        if (hookExact(table[i].cls, table[i].sel, table[i].meta)) n++;
    }
    return n;
}

#pragma mark - present 拦截

static void (*orig_present)(id, SEL, id, BOOL, id) = NULL;

static BOOL nameLooksLikeAdVC(const char *n) {
    if (!n) return NO;
    if (strstr(n, "Splash") && (strstr(n, "Ad") || strstr(n, "GDT") || strstr(n, "TME") || strstr(n, "Flash"))) return YES;
    if (strstr(n, "QMGDTSplash") || strstr(n, "QMTMEAdSplash")) return YES;
    if (strstr(n, "Interstitial") || strstr(n, "Intersititial")) return YES;
    if (strstr(n, "Reward") && strstr(n, "Ad") &&
        (strstr(n, "Controller") || strstr(n, "ViewController") || strstr(n, "VC"))) return YES;
    if (strstr(n, "QMRewardAdViewController")) return YES;
    if (strstr(n, "GDTSplash") || strstr(n, "GDTUnified") || strstr(n, "GDTReward")) return YES;
    if (strstr(n, "TMEAdSplash") || strstr(n, "TMEAdInterstitial") || strstr(n, "TMEAdReward")) return YES;
    if (strstr(n, "SKStoreProduct") || strstr(n, "SMStoreProduct")) return YES;
    if (strstr(n, "SongPageAd") && strstr(n, "Controller")) return YES;
    return NO;
}

static void hooked_present(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL anim, id completion) {
    if (vc) {
        const char *n = class_getName(object_getClass(vc));
        if (nameLooksLikeAdVC(n)) {
            QMLog(@"block present %s", n);
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

#pragma mark - 广告 View 折叠（不碰 UIView 根类）

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

    if (!class_addMethod(cls, sel, (IMP)hooked_didMove, enc)) {
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
        "QMSongFrontAdView",
        "QMSongPageAdView",
        "QMSongPageAdView_Horizontal",
        "QMSongPageAdView_Vertical",
        "QMSongPageAdView_Podcast",
        "QMSongPageAdFullScreenView",
        "QMSongPageAdNativeRewardView",
        "QMChannelBeltAdCell",
        "QMFreeModeMyMusicBeltAdCell",
        "QMLongTrackBeltAdCellTableViewCell",
        "KSBannerAdBaseView",
        "TMEAdNativeView",
        "TMEAdMaskBannerView",
        "TGGDTPendantView",
        "GDTUnifiedBannerView",
        NULL
    };
    for (int i = 0; views[i]; i++) swizzleDidMove(views[i]);
}

#pragma mark - Entry

static void applyAll(const char *tag) {
    int n = 0;
    @try {
        n = applyExactHooks();
        installViewHooks();
    } @catch (NSException *e) {
        NSLog(@"[QQMusic] %@ exception %@", @(tag), e);
        return;
    }
    QMLog(@"%s hooks=%d", tag, n);
}

static void onForeground(void) {
    applyAll("fg");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ applyAll("fg+0.5"); });
}

__attribute__((constructor))
static void QQMusicDylibInit(void) {
    @autoreleasepool {
        NSLog(@"[QQMusic] dylib loaded (v1 ad-block)");

        @try { installPresentHook(); } @catch (__unused NSException *e) {}

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                applyAll("main");
                [[NSNotificationCenter defaultCenter]
                 addObserverForName:UIApplicationWillEnterForegroundNotification
                 object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(__unused NSNotification *n) { onForeground(); }];
            } @catch (NSException *e) {
                NSLog(@"[QQMusic] main init exception %@", e);
            }
        });

        // 懒加载类补 hook（主线程）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyAll("+2s"); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyAll("+5s"); });
    }
}
