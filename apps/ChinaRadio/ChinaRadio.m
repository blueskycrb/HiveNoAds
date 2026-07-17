//
// ChinaRadio.dylib — 中国广电 / ChinaRadio 去广告 (TrollFools)
// Bundle: com.cbn.app | 可执行文件: ChinaRadio
// 分析版本: 2.0.8 (decrypted arm64)
//
// 广告栈 (静态分析，无主流三方广告聚合 SDK):
//   首页弹窗: AdPopView / createHomeView_popAdView / isShowPop / showPop*
//   首页底部广告轮播: HomeBottomAdCycleScrollView / createHomeView_bottomAdCycleScrollView
//                     homeBottomAdArray / homeADArray
//   首页运营/营销: HomeMarketView / createHomeView_bottomMarketView
//                  homeMarketingArray / homeMarketingArr
//                  createHomeView_bottomGDView
//   首页/分类/我的 Banner 轮播:
//                  HomeCycleScrollView / ClassCycleScrollView / MineCycleScrollView
//                  homeBannerArray / classBannerArray / mineBannerArray
//                  sendCycleScrollViewDataRequest
//   其它运营字段: dateRechargeBanner / littleLeaveBanner / clickAd
//   通用弹层 (仅广告向): PopupView / BottonPopView / AutomaticPopView
//   注意: IdentityPopView / ReportPopView / ChangePopView 偏业务弹窗，不折叠
//
// v1 原则（对齐 mCloud_iPhone / HiveConsumer v4）:
//   - 不依赖 MobileSubstrate；纯 objc runtime
//   - 禁止 objc_copyClassList 全量扫描
//   - 禁止 hook 全体 UIView / openURL
//   - 只改「本类 method list」实现，避免污染父类
//   - 仅 stub 返回 void / BOOL / id 且参数为对象指针的方法
//   - 对 setXxxArray: 用「写空数组」替换，避免业务空解引用
//   - View 折叠只针对白名单广告类
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static const BOOL kVerbose = NO;
#define CRLog(fmt, ...) do { if (kVerbose) NSLog(@"[ChinaRadio] " fmt, ##__VA_ARGS__); } while (0)

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

/// setXxxArray: / setXxxArr: → 强制写成空可变数组，避免业务对 nil 解引用
static void stub_emptyArray1(id s, SEL c, id a) {
    (void)a;
    const char *selName = sel_getName(c);
    if (!selName) return;
    @try {
        NSString *selStr = [NSString stringWithUTF8String:selName];
        if ([selStr hasPrefix:@"set"] && [selStr hasSuffix:@":"] && selStr.length > 4) {
            NSString *key = [selStr substringWithRange:NSMakeRange(3, selStr.length - 4)];
            if (key.length) {
                NSString *prop = [[key substringToIndex:1].lowercaseString
                                  stringByAppendingString:[key substringFromIndex:1]];
                [s setValue:[NSMutableArray array] forKey:prop];
                CRLog(@"empty %@", prop);
            }
        }
    } @catch (__unused NSException *e) {}
}

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
    // 数组 setter 用空数组 stub
    if (strstr(sname, "Array:") || strstr(sname, "Arr:") ||
        strcmp(sname, "setHomeADArray:") == 0 ||
        strcmp(sname, "setHomeBottomAdArray:") == 0 ||
        strcmp(sname, "setHomeBannerArray:") == 0 ||
        strcmp(sname, "setHomeMarketingArray:") == 0 ||
        strcmp(sname, "setHomeMarketingArr:") == 0 ||
        strcmp(sname, "setClassBannerArray:") == 0 ||
        strcmp(sname, "setMineBannerArray:") == 0 ||
        strcmp(sname, "setHomeLampArray:") == 0) {
        unsigned argc = method_getNumberOfArguments(own);
        const char *enc = method_getTypeEncoding(own);
        if (enc && enc[0] == 'v' && argc == 3) {
            stub = (IMP)stub_emptyArray1;
        }
    }
    if (!stub) {
        if (!canSafelyStub(own, &stub) || !stub) {
            CRLog(@"skip unsafe %c[%s %s]", meta ? '+' : '-', cname, sname);
            return NO;
        }
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
        strstr(name, "popAd") || strstr(name, "PopAd") ||
        strstr(name, "bottomAd") || strstr(name, "BottomAd") ||
        strstr(name, "clickAd") || strstr(name, "ClickAd") ||
        strcmp(name, "isShowPop") == 0 ||
        strcmp(name, "showPop") == 0 ||
        strcmp(name, "showPop:") == 0 ||
        strcmp(name, "showPopView") == 0 ||
        strstr(name, "createHomeView_popAd") ||
        strstr(name, "createHomeView_bottomAd") ||
        strstr(name, "createHomeView_bottomMarket") ||
        strstr(name, "createHomeView_bottomGD") ||
        strstr(name, "sendCycleScrollViewDataRequest") ||
        strstr(name, "dateRechargeBanner") ||
        strstr(name, "littleLeaveBanner");
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

#pragma mark - Known ChinaRadio ad classes

static const char *kAdControlClasses[] = {
    "AdPopView",
    "HomeBottomAdCycleScrollView",
    "HomeCycleScrollView",
    "ClassCycleScrollView",
    "MineCycleScrollView",
    "HomeMarketView",
    "HomeViewController",
    "HomeViewModel",
    "HomeModel",
    "ClassViewController",
    "ClassViewModel",
    "MineViewController",
    "MineViewModel",
    "PopupView",
    "BottonPopView",
    "AutomaticPopView",
    "LampScroll",
    "AccountPopup",
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
        // —— 首页创建广告视图 ——
        { "HomeViewController", "createHomeView_popAdView", NO },
        { "HomeViewController", "createHomeView_bottomAdCycleScrollView", NO },
        { "HomeViewController", "createHomeView_bottomMarketView", NO },
        { "HomeViewController", "createHomeView_bottomGDView", NO },
        { "HomeViewController", "createHomeView_cycleScrollView", NO },
        // recommend / prefecture 可能是内容专区，不 stub 创建
        { "HomeViewController", "clickAd", NO },
        { "HomeViewController", "showPop", NO },
        { "HomeViewController", "showPop:", NO },
        { "HomeViewController", "showPopView", NO },
        { "HomeViewController", "sendCycleScrollViewDataRequest", NO },

        // —— 分类 / 我的 Banner 轮播（只 stub 创建轮播与广告请求，不碰整页数据）——
        { "ClassViewController", "createClassView_cycleScrollView", NO },
        { "ClassViewController", "sendCycleScrollViewDataRequest", NO },
        { "MineViewController", "createMineView_cycleScrollView", NO },
        { "MineViewController", "sendCycleScrollViewDataRequest", NO },

        // —— 数据模型：广告/运营数组置空（保留 recommend / prefecture 内容区）——
        { "HomeModel", "setHomeADArray:", NO },
        { "HomeModel", "setHomeBottomAdArray:", NO },
        { "HomeModel", "setHomeBannerArray:", NO },
        { "HomeModel", "setHomeMarketingArray:", NO },
        { "HomeModel", "setHomeMarketingArr:", NO },
        { "HomeModel", "setHomeLampArray:", NO },
        { "HomeModel", "setClassBannerArray:", NO },
        { "HomeModel", "setMineBannerArray:", NO },

        { "HomeViewModel", "setHomeADArray:", NO },
        { "HomeViewModel", "setHomeBottomAdArray:", NO },
        { "HomeViewModel", "setHomeBannerArray:", NO },
        { "HomeViewModel", "setHomeMarketingArray:", NO },
        { "HomeViewModel", "setHomeMarketingArr:", NO },
        { "HomeViewModel", "setHomeLampArray:", NO },
        { "HomeViewModel", "setClassBannerArray:", NO },
        { "HomeViewModel", "setMineBannerArray:", NO },
        { "HomeViewModel", "sendCycleScrollViewDataRequest", NO },

        { "ClassViewModel", "setClassBannerArray:", NO },
        { "MineViewModel", "setMineBannerArray:", NO },

        // —— 弹窗广告 ——
        { "AdPopView", "showPop", NO },
        { "AdPopView", "showPop:", NO },
        { "AdPopView", "showPopView", NO },
        { "AdPopView", "clickAd", NO },
        { "PopupView", "showPop", NO },
        { "PopupView", "showPop:", NO },
        { "PopupView", "showPopView", NO },
        { "AutomaticPopView", "showPop", NO },
        { "AutomaticPopView", "showPop:", NO },
        { "AutomaticPopView", "showPopView", NO },
        { "BottonPopView", "showPop", NO },
        { "BottonPopView", "showPop:", NO },
        { "BottonPopView", "showPopView", NO },
        { "AccountPopup", "showPop", NO },
        { "AccountPopup", "showPop:", NO },

        // isShowPop → NO
        { "HomeViewController", "isShowPop", NO },
        { "HomeViewModel", "isShowPop", NO },
        { "HomeModel", "isShowPop", NO },
        { "AdPopView", "isShowPop", NO },

        { NULL, NULL, NO }
    };

    for (int i = 0; table[i].cls; i++) {
        if (hookExact(table[i].cls, table[i].sel, table[i].meta)) n++;
    }
    return n;
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
    // 同步约束高度（若有）
    for (NSLayoutConstraint *c in v.constraints) {
        if (c.firstAttribute == NSLayoutAttributeHeight && c.firstItem == v) {
            c.constant = 0;
        }
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
        "AdPopView",
        "HomeBottomAdCycleScrollView",
        "HomeCycleScrollView",
        "ClassCycleScrollView",
        "MineCycleScrollView",
        "HomeMarketView",
        "PopupView",
        "BottonPopView",
        "AutomaticPopView",
        "LampScroll",
        "AccountPopup",
        NULL
    };
    for (int i = 0; views[i]; i++) swizzleDidMove(views[i]);
}

#pragma mark - present 拦截广告弹层 VC（保守）

static void (*orig_present)(id, SEL, id, BOOL, id) = NULL;

static BOOL nameLooksLikeAdVC(const char *n) {
    if (!n) return NO;
    if (strstr(n, "AdPop")) return YES;
    if (strstr(n, "Advert") || strstr(n, "advert")) return YES;
    if (strstr(n, "SplashAd") || strstr(n, "LaunchAd")) return YES;
    // 不误伤 Identity / Report / Change / Agreement / Login 等业务弹窗
    if (strstr(n, "Identity") || strstr(n, "Report") || strstr(n, "Change") ||
        strstr(n, "Agreement") || strstr(n, "Login") || strstr(n, "Privacy") ||
        strstr(n, "Cancel") || strstr(n, "Face") || strstr(n, "Pay")) {
        return NO;
    }
    return NO;
}

static void hooked_present(UIViewController *self, SEL _cmd, UIViewController *vc, BOOL anim, id completion) {
    if (vc) {
        const char *n = class_getName(object_getClass(vc));
        if (nameLooksLikeAdVC(n)) {
            CRLog(@"block present %s", n);
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

#pragma mark - Entry

static void applyAll(const char *tag) {
    int exact = 0, list = 0;
    @try {
        exact = applyExactHooks();
        list = applyClassListHooks();
        installViewHooks();
    } @catch (NSException *e) {
        NSLog(@"[ChinaRadio] %@ exception %@", @(tag), e);
        return;
    }
    CRLog(@"%s exact=%d list=%d", tag, exact, list);
}

static void onForeground(void) {
    applyAll("fg");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ applyAll("fg+0.5"); });
}

__attribute__((constructor))
static void ChinaRadioDylibInit(void) {
    @autoreleasepool {
        NSLog(@"[ChinaRadio] dylib loaded (v1 NoAds, target 2.0.8 / com.cbn.app)");

        @try { installPresentHook(); } @catch (__unused NSException *e) {}

        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                applyAll("main");
                [[NSNotificationCenter defaultCenter]
                 addObserverForName:UIApplicationWillEnterForegroundNotification
                 object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(__unused NSNotification *note) { onForeground(); }];
            } @catch (NSException *e) {
                NSLog(@"[ChinaRadio] main init exception %@", e);
            }
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            applyAll("+1.5s");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            applyAll("+3s");
        });
    }
}
