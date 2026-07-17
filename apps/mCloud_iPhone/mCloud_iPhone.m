//
// mCloud_iPhone.dylib — 中国移动云盘去广告 (TrollFools)
// Bundle: com.chinamobile.mcloud | 可执行文件: mCloud_iPhone
// 分析版本: 13.0.0 (decrypted arm64)
//
// 广告栈 (静态分析):
//   开屏/启动: StartPageManager / OpenScreenAdvertising / pushLunchtAdvertController
//              MainWindowViewController delayInitTabBarControllerAfterSplashAdvert
//   业务中台: MCAdvertInfoCenter / MCAdvertTools / MCGetAdverts / MCAdvertRequest
//   网络: MCMarketGetAdInfoNetworkService / HNBatchGetAdInfoListManager
//         HNGetAdInfoFilterManager / advert/getAdInfos / adv-filter/*
//   首页/发现/备份/会员/视频/圈子等 Banner 与运营位:
//         MCHomepageAdvertBannerCell / MCFolderMetuTopAdView / MCHomeAutoBackUp*Ad*
//         MCMemberAD* / MCMine*Advert* / MCVideo*AD* / MCCircle*Advert*
//         MCFamily*Advert* / MCNewWebAdvertView / HNAdvertPopView ...
//
// v1 原则（对齐 HiveConsumer v4 / Cainiao 定点 hook，防崩）:
//   - 不依赖 MobileSubstrate；纯 objc runtime
//   - 禁止 objc_copyClassList 全量扫描
//   - 禁止 hook 全体 UIView / openURL
//   - 只改「本类 method list」实现，避免污染父类
//   - 仅 stub 返回 void / BOOL / id 且参数为对象指针的方法
//   - present 仅拦截广告 VC 名；View 折叠只针对白名单广告类
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static const BOOL kVerbose = NO;
#define MCLog(fmt, ...) do { if (kVerbose) NSLog(@"[mCloud_iPhone] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - Minimal stubs

static void stub_v0(id s, SEL c) { (void)s; (void)c; }
static void stub_v1(id s, SEL c, id a) { (void)s; (void)c; (void)a; }
static void stub_v2(id s, SEL c, id a, id b) { (void)s; (void)c; (void)a; (void)b; }
static void stub_v3(id s, SEL c, id a, id b, id d) {
    (void)s; (void)c; (void)a; (void)b; (void)d;
}
static void stub_v4(id s, SEL c, id a, id b, id d, id e) {
    (void)s; (void)c; (void)a; (void)b; (void)d; (void)e;
}
static BOOL stub_NO(id s, SEL c) { (void)s; (void)c; return NO; }
static BOOL stub_NO1(id s, SEL c, id a) { (void)s; (void)c; (void)a; return NO; }
static id stub_nil0(id s, SEL c) { (void)s; (void)c; return nil; }
static id stub_nil1(id s, SEL c, id a) { (void)s; (void)c; (void)a; return nil; }
static id stub_nil2(id s, SEL c, id a, id b) { (void)s; (void)c; (void)a; (void)b; return nil; }
static id stub_nil3(id s, SEL c, id a, id b, id d) {
    (void)s; (void)c; (void)a; (void)b; (void)d; return nil;
}

/// 仅当：返回 void/BOOL/id，参数个数匹配，且 type encoding 里参数全是指针类 (@ : ^ # *) 时才 hook
static BOOL canSafelyStub(Method m, IMP *outImp) {
    if (!m || !outImp) return NO;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || !enc[0]) return NO;

    char ret = enc[0];
    if (ret != 'v' && ret != 'B' && ret != 'c' && ret != '@') return NO;

    unsigned argc = method_getNumberOfArguments(m); // includes self,_cmd
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
            return NO; // 值类型不 hook
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

/// 只改本类 method list，避免 class_getInstanceMethod 落到父类后污染全局
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
        MCLog(@"skip unsafe %c[%s %s]", meta ? '+' : '-', cname, sname);
        return NO;
    }
    if (method_getImplementation(own) != stub) {
        method_setImplementation(own, stub);
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
        strstr(name, "loadAdvert") || strstr(name, "showAdvert") ||
        strstr(name, "requestAdvert") || strstr(name, "fetchAdvert") ||
        strstr(name, "getAdvert") || strstr(name, "getAdverts") ||
        strstr(name, "batchGetAd") || strstr(name, "batchGetAdvert") ||
        strstr(name, "getAdInfo") || strstr(name, "getAdList") ||
        strstr(name, "loadADData") || strstr(name, "loadAdData") ||
        strstr(name, "configAd") || strstr(name, "configAdvert") ||
        strstr(name, "updateAdvert") || strstr(name, "updataAdvert") ||
        strstr(name, "pushLunchtAdvert") || strstr(name, "pushToLunchAdvert") ||
        strstr(name, "pushToAdvert") || strstr(name, "showAdver") ||
        strcmp(name, "isReady") == 0 || strcmp(name, "isAdValid") == 0 ||
        strcmp(name, "canShowAd") == 0 || strcmp(name, "shouldShowAd") == 0 ||
        strcmp(name, "isShowingLaunchAdvert") == 0 ||
        strcmp(name, "hasAdvert") == 0 || strcmp(name, "hasAdInfo") == 0 ||
        strcmp(name, "showAdvert") == 0 || strcmp(name, "displayAdvert") == 0;
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
        if (!selectorIsAdControl(name)) continue;
        IMP replacement = NULL;
        if (!canSafelyStub(methods[i], &replacement) || !replacement) continue;
        if (method_getImplementation(methods[i]) != replacement) {
            method_setImplementation(methods[i], replacement);
            hooked++;
        }
    }
    free(methods);

    Class meta = object_getClass((id)cls);
    count = 0;
    methods = meta ? class_copyMethodList(meta, &count) : NULL;
    for (unsigned i = 0; methods && i < count; i++) {
        SEL selector = method_getName(methods[i]);
        const char *name = sel_getName(selector);
        if (!selectorIsAdControl(name)) continue;
        IMP replacement = NULL;
        if (!canSafelyStub(methods[i], &replacement) || !replacement) continue;
        if (method_getImplementation(methods[i]) != replacement) {
            method_setImplementation(methods[i], replacement);
            hooked++;
        }
    }
    free(methods);
    return hooked;
}

#pragma mark - Known mCloud ad classes (whitelist)

static const char *kAdControlClasses[] = {
    // 启动开屏
    "StartPageManager",
    "OpenScreenAdvertising",
    "BootAnimation",

    // 广告中台 / 工具
    "MCAdvertInfoCenter",
    "MCAdvertTools",
    "MCAdvertRequest",
    "MCAdvert",
    "MCAdvertInfo",
    "MCAdvertBanner",
    "MCAdvertModel",
    "MCAdvertMaterial",
    "MCGetAdverts",
    "MCSspAdvertInfoTable",
    "MCAdvertInfoTable",

    // 网络 / 批量拉取
    "MCMarketGetAdInfoNetworkService",
    "MCMarketGetAdConfigAdInfoNetworkService",
    "Target_MCMarketGetAdInfoNetworkService",
    "Target_MCMarketGetAdConfigAdInfoNetworkService",
    "HNBatchGetAdInfoListManager",
    "HNGetAdInfoFilterManager",
    "HNGetAdInfosMaterialObj",
    "MCGetAdInfosModel",
    "MCAlbumGetAdInfosModel",
    "MCAICameraBatchGetAdInfosReq",

    // 业务广告 Manager / ViewModel
    "MCCircleAdManager",
    "MCThreeColumnAdvertManager",
    "MCMineOperationAdManager",
    "MCMineOperationAdViewModel",
    "MCMineWalletADViewModel",
    "MCAcrCoADViewModel",
    "MCMoreVideoAdvertViewModel",
    "MCVideoPlayerADViewModel",
    "MCFamilyHomePageAdvertViewModel",
    "MCCircleFamilyNetsHomeAdModel",
    "MCAlbumBackupAdWithPPSDKManagerUpdateAdverts",

    // 视图容器（控制方法）
    "MCFolderMetuTopAdView",
    "MCHomeAutoBackUpAdView",
    "MCHomepageAdvertBannerCell",
    "MCADCicleBannerView",
    "MCADCicleBannerModel",
    "MCADCicleBannerCache",
    "MCADCircleDetailBannerView",
    "MCADBannerView",
    "MCExpandADBannerView",
    "MCNewWebAdvertView",
    "HNAdvertPopView",
    "HNNoteListAdvertCell",
    "MCFamilyHomePageAdvertView",
    "MCFamilyNetHotRecommendAdvertView",
    "MCCircleDynamicAdvertView",
    "MCCircleFirstPageRotationAdvertView",
    "MCCircleOldAdvertCell",
    "MCMineVipAdvertView",
    "MCMineAcrCoADCell",
    "MCMineManyLinesAdvertCell",
    "MCMineManyLinesAdvertNewCell",
    "MCMineOperationalAdCell",
    "MCThreeColumnAdvertCell",
    "MCMemberADCollectionViewCell",
    "MCHomeAutoBackUpOnePartAdCollectionViewCell",
    "MCHomeAutoBackUpTwoPartAdCollectionViewCell",
    "MCOneADCollectionViewCellHomeAutoBackUp",
    "MCAutoBackUpPPSDKAdView",
    "MCTourisModeAutoBackUpAdView",
    "MCTouristModeV3AdView",
    "MCStorageDiskAdView",
    "MCStorageDiskBackupAdCell",
    "MCVideoADView",
    "MCVideoPlayPauseADView",
    "MCVideoPlayWordADView",
    "MCAlbumPhotosShowBannerView",
    "MCAlbumPhotosShowBannerCollectionViewCell",
    "MCAlbumToolBanner",
    "MCDiscoveryBigBannerCell",
    "MCDiscoveryBigBannerView",
    "MCDiscoverySmallBannerCell",
    "MCRecommendedCardBannerCell",
    "MCRecommendedCardBannerView",
    "MyAdvertDetailViewController",
    "MyAdvertDetailWithStatusBarViewController",
    "NewMarketAdvertViewController",

    // 投屏/电视广告接口（若存在）
    "LBADInterface",
    NULL
};

static int applyClassListHooks(void) {
    int n = 0;
    for (int i = 0; kAdControlClasses[i]; i++) {
        n += hookAdControlsOnClass(kAdControlClasses[i]);
    }
    return n;
}

static int applyExactHooks(void) {
    int n = 0;
    const struct { const char *cls; const char *sel; BOOL meta; } table[] = {
        // —— 启动开屏主链路 ——
        { "StartPageManager", "getAdvertCallBack:", NO },
        { "StartPageManager", "getMartketAdvertCallBack:", NO },
        { "StartPageManager", "handleMartketAdvertCallBack:isSuccess:", NO },
        { "StartPageManager", "homeFetchMarketAdvert:", NO },
        { "StartPageManager", "backgroundMarketAdvert", NO },
        { "StartPageManager", "downLoadStartPageWithAdvertType:", NO },
        { "StartPageManager", "getYdrzAdvertDataWithArray:complete:", NO },
        { "StartPageManager", "queryYdrzAdDataWithContactId:", NO },
        { "StartPageManager", "reportDisplayAdInfoAdvertId:adPosId:adTag:", NO },
        { "StartPageManager", "backgroundHandler:", NO },

        // 主窗口开屏展示入口：只拦「推广告 / 弹广告」，
        // 绝不 hook delayInitTabBarControllerAfterSplashAdvert —— 那是进主 Tab 的入口，stub 会卡启动。
        { "MainWindowViewController", "pushLunchtAdvertController", NO },
        { "MainWindowViewController", "pushLunchtAdvertController:", NO },
        { "MainWindowViewController", "pushToLunchAdvertDetailViewController", NO },
        { "MainWindowViewController", "showAdverPopView:clickAdvert:", NO },
        { "MainWindowViewController", "showAdWithTabIndex:tab2Index:", NO },

        // —— 广告中台 ——
        { "MCAdvertInfoCenter", "fetchAdvertInfoWithTpye:context:error:", NO },
        { "MCAdvertInfoCenter", "getMartketAdvertCallBack:", NO },
        { "MCAdvertInfoCenter", "getSspAdvertInfoWithAdvertPos:", NO },
        { "MCAdvertInfoCenter", "pushToAdvertViewControllFor:from:completedBlock:", NO },
        { "MCAdvertInfoCenter", "downloadImageForAdvert:", NO },
        { "MCAdvertInfoCenter", "downloadImageForSspAdvert:withImageFilePath:", NO },
        { "MCAdvertInfoCenter", "reportSspAdvertWithEventType:sspAdvertImps:target:selector:", NO },

        { "MCAdvertTools", "advertContiue:record:judgeImg:imagePath:index:", YES },
        { "MCAdvertTools", "advertCounting:record:judgeImg:imagePath:index:", YES },
        { "MCAdvertTools", "advertFirstTimeConfig:index:", YES },
        { "MCAdvertTools", "advertHandleAgain:record:index:", YES },
        { "MCAdvertTools", "judgeAdvert:record:index:", YES },
        { "MCAdvertTools", "judgeAdvertData:judgeImg:imagePath:", YES },
        { "MCAdvertTools", "saveAdvertData:index:", YES },
        { "MCAdvertTools", "saveAdvertData:judgeRule:index:", YES },

        // —— 批量 / 过滤广告接口 ——
        { "HNBatchGetAdInfoListManager", "getBatchAdLists:callBackListArr:", YES },
        { "HNBatchGetAdInfoListManager", "getBatchAdSingle:callBack:", YES },
        { "HNBatchGetAdInfoListManager", "getBatchAdSingle:andTag:callBack:", YES },
        { "HNGetAdInfoFilterManager", "getAdInfoFilter:callBackListArr:", YES },

        // —— 圈子 / 视频 / 备份卡片 ——
        { "MCCircleAdManager", "showAdWithRes:", NO },
        { "MCCircleAdManager", "loadLoveFamilyCircleAdvertList", NO },
        { "MCCircleAdManager", "reloadFailAdvert", NO },
        { "MCCircleAdManager", "getCircleAdInfoReq:", NO },
        { "MCCircleAdManager", "get66398AdInfoReq:", YES },
        { "MCCircleAdManager", "queryCircleAdInfoDataWithAdpostid:comple:", YES },
        { "MCCircleAdManager", "queryFamilyCircleRightTopEntryAdInfoData:", YES },

        { "MCFolderMetuTopAdView", "loadADData", NO },
        { "MCHomeBackupCardCell", "configAd", NO },

        { "MCMoreVideoAdvertViewModel", "get66560VideoAdvertRequest:", NO },
        { "MCMoreVideoAdvertViewModel", "get66561VideoAdvertRequest:", NO },
        { "MCMoreVideoAdvertViewModel", "get66582VideoAdvertRequest:", NO },

        { "MCVideoPlayerADViewModel", "getAdListInfo", NO },
        { "MCVideoPlayerADViewModel", "getPauseAdInfo", NO },
        { "MCVideoPlayerADViewModel", "getWordAdInfo", NO },
        { "MCVideoPlayerADViewModel", "checkAdvertWithList:advertId:complete:", NO },

        { "MCAcrCoADViewModel", "getAdDetail:", NO },
        { "MCAcrCoADViewModel", "closeADWithState:", NO },

        { "MCNewWebAdvertView", "setUI:", NO },
        { "MyAdvertDetailViewController", "requestData", NO },
        { "MyAdvertDetailViewController", "prepareHomePageH5Preload", NO },

        // 投屏广告
        { "LBADInterface", "fetchAdInfoWithAdPosition:param:timeOut:completeHandler:", YES },

        { NULL, NULL, NO }
    };

    for (int i = 0; table[i].cls; i++) {
        if (hookExact(table[i].cls, table[i].sel, table[i].meta)) n++;
    }
    return n;
}

#pragma mark - present 拦截广告 VC

static void (*orig_present)(id, SEL, id, BOOL, id) = NULL;

static BOOL nameLooksLikeAdVC(const char *n) {
    if (!n) return NO;
    if (strstr(n, "Advert") || strstr(n, "advert")) return YES;
    if (strstr(n, "SplashAd") || strstr(n, "OpenScreen") || strstr(n, "LaunchAdvert")) return YES;
    if (strstr(n, "LunchtAdvert") || strstr(n, "StartPage")) return YES;
    if (strstr(n, "MyAdvertDetail") || strstr(n, "NewMarketAdvert")) return YES;
    if (strstr(n, "WebAdvert") || strstr(n, "HNAdvert")) return YES;
    if (strstr(n, "GDTSplash") || strstr(n, "BUSplash") || strstr(n, "CSJSplash") ||
        strstr(n, "KSSplash") || strstr(n, "MSSplash") || strstr(n, "UBiXSplash")) return YES;
    if (strstr(n, "Interstitial") && strstr(n, "Ad")) return YES;
    if (strstr(n, "Reward") && strstr(n, "Ad") && strstr(n, "Controller")) return YES;
    // 避免误伤 AddressBook 等
    if (strstr(n, "Address") || strstr(n, "Adress")) return NO;
    return NO;
}

static void hooked_present(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL anim, id completion) {
    if (vc) {
        const char *n = class_getName(object_getClass(vc));
        if (nameLooksLikeAdVC(n)) {
            MCLog(@"block present %s", n);
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
    v.clipsToBounds = YES;
    CGRect frame = v.frame;
    if (frame.size.height > 0.5) {
        frame.size.height = 0;
        v.frame = frame;
    }
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
        "MCFolderMetuTopAdView",
        "MCFolderMetuTopAdViewCell",
        "MCHomeAutoBackUpAdView",
        "MCHomepageAdvertBannerCell",
        "MCADCicleBannerView",
        "MCADCircleDetailBannerView",
        "MCADBannerView",
        "MCExpandADBannerView",
        "MCNewWebAdvertView",
        "HNAdvertPopView",
        "HNNoteListAdvertCell",
        "MCFamilyHomePageAdvertView",
        "MCFamilyNetHotRecommendAdvertView",
        "MCCircleDynamicAdvertView",
        "MCCircleFirstPageRotationAdvertView",
        "MCCircleOldAdvertCell",
        "MCMineVipAdvertView",
        "MCMineAcrCoADCell",
        "MCMineManyLinesAdvertCell",
        "MCMineManyLinesAdvertNewCell",
        "MCMineOperationalAdCell",
        "MCThreeColumnAdvertCell",
        "MCMemberADCollectionViewCell",
        "MCHomeAutoBackUpOnePartAdCollectionViewCell",
        "MCHomeAutoBackUpTwoPartAdCollectionViewCell",
        "MCOneADCollectionViewCellHomeAutoBackUp",
        "MCAutoBackUpPPSDKAdView",
        "MCTourisModeAutoBackUpAdView",
        "MCTouristModeV3AdView",
        "MCStorageDiskAdView",
        "MCStorageDiskBackupAdCell",
        "MCVideoADView",
        "MCVideoPlayPauseADView",
        "MCVideoPlayWordADView",
        "MCAlbumPhotosShowBannerView",
        "MCAlbumPhotosShowBannerCollectionViewCell",
        "MCDiscoveryBigBannerCell",
        "MCDiscoveryBigBannerView",
        "MCDiscoverySmallBannerCell",
        "MCRecommendedCardBannerCell",
        "MCRecommendedCardBannerView",
        "MCAlbumToolBanner",
        "MCHKBannerCell",
        "MCMemoryAlbumBannerView",
        "MCMemoryBannerItemCell",
        NULL
    };
    for (int i = 0; views[i]; i++) swizzleDidMove(views[i]);
}

#pragma mark - Launch advert safety net

/// 开屏广告被 stub 后，业务可能仍在等 dismiss；主动打通知，避免卡在启动页。
static void forceDismissLaunchAdvert(void) {
    @try {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        // 二进制中可见的通知名
        [nc postNotificationName:@"gMCLaunchAdvertDismissNotification" object:nil];
        [nc postNotificationName:@"LunchtAdvertStatusNotification" object:nil userInfo:nil];

        // 若 MainWindow 上有 dismiss 方法则调用（不存在则忽略）
        Class mainCls = objc_getClass("MainWindowViewController");
        UIApplication *app = [UIApplication sharedApplication];
        UIViewController *root = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in app.connectedScenes) {
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { root = w.rootViewController; break; }
                }
                if (root) break;
            }
        }
        if (!root) root = app.keyWindow.rootViewController;

        UIViewController *top = root;
        while (top.presentedViewController) top = top.presentedViewController;
        if (mainCls && top && [top isKindOfClass:mainCls]) {
            SEL sels[] = {
                sel_registerName("lauchAdvertDismiss"),
                sel_registerName("launchAdvertDismiss"),
                sel_registerName("delayInitTabBarControllerAfterSplashAdvert"),
            };
            for (int i = 0; i < 3; i++) {
                if ([top respondsToSelector:sels[i]]) {
                    #pragma clang diagnostic push
                    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [top performSelector:sels[i]];
                    #pragma clang diagnostic pop
                    MCLog(@"called %s on MainWindow", sel_getName(sels[i]));
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[mCloud_iPhone] forceDismiss exception %@", e);
    }
}

#pragma mark - Entry

static void applyAll(const char *tag) {
    int exact = 0, list = 0;
    @try {
        exact = applyExactHooks();
        list = applyClassListHooks();
        installViewHooks();
    } @catch (NSException *e) {
        NSLog(@"[mCloud_iPhone] %@ exception %@", @(tag), e);
        return;
    }
    MCLog(@"%s exact=%d list=%d", tag, exact, list);
}

static void onForeground(void) {
    applyAll("fg");
    forceDismissLaunchAdvert();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ applyAll("fg+0.5"); });
}

__attribute__((constructor))
static void mCloud_iPhoneDylibInit(void) {
    @autoreleasepool {
        NSLog(@"[mCloud_iPhone] dylib loaded (v1 NoAds, target 13.0.0)");

        @try { installPresentHook(); } @catch (__unused NSException *e) {}

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                applyAll("main");
                forceDismissLaunchAdvert();
                [[NSNotificationCenter defaultCenter]
                 addObserverForName:UIApplicationWillEnterForegroundNotification
                 object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(__unused NSNotification *note) { onForeground(); }];
            } @catch (NSException *e) {
                NSLog(@"[mCloud_iPhone] main init exception %@", e);
            }
        });

        // 懒加载类补 hook（主线程，避免后台改 method 竞态）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            applyAll("+1.5s");
            forceDismissLaunchAdvert();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            applyAll("+3s");
            forceDismissLaunchAdvert();
        });
    }
}
