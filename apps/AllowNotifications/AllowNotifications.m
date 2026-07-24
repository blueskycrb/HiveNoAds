//
// AllowNotifications.dylib — auto-allow notification permission (HiveNoAds apps build)
//
// Inject into target App (TrollFools). Automatically handles:
//   "xxx 想给你发送通知" / Would Like to Send You Notifications
//
// Pure Objective-C runtime hooks (no Substrate/Logos), same style as other apps/*.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static const BOOL kVerbose = NO;
#define ALNLog(fmt, ...) do { if (kVerbose) NSLog(@"[AllowNotifications] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - Text helpers

static BOOL ALNContainsAny(NSString *text, NSArray<NSString *> *needles) {
    if (text.length == 0) return NO;
    for (NSString *n in needles) {
        if (n.length && [text containsString:n]) return YES;
    }
    return NO;
}

static BOOL ALNIsNotificationPromptText(NSString *text) {
    if (text.length == 0) return NO;

    static NSArray<NSString *> *cn;
    static NSArray<NSString *> *en;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cn = @[
            @"想给你发送通知",
            @"想給你發送通知",
            @"发送通知",
            @"發送通知",
            @"傳送通知",
            @"传送通知",
            @"通知可能包括",
            @"提醒、声音和图标标记",
            @"提醒、聲音和圖示標記",
        ];
        en = @[
            @"would like to send you notifications",
            @"wants to send you notifications",
            @"send you notifications",
        ];
    });

    if (ALNContainsAny(text, cn)) return YES;

    NSString *lower = text.lowercaseString;
    if (ALNContainsAny(lower, en)) return YES;

    if ([lower containsString:@"notifications"] &&
        ([lower containsString:@"badge"] ||
         [lower containsString:@"sound"] ||
         [lower containsString:@"reminders"] ||
         [lower containsString:@"alerts"])) {
        return YES;
    }
    return NO;
}

static BOOL ALNIsAllowTitle(NSString *title) {
    if (title.length == 0) return NO;
    static NSArray<NSString *> *allows;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        allows = @[
            @"允许", @"允許", @"好", @"好的", @"确定", @"確定",
            @"Allow", @"OK", @"Yes", @"允许通知"
        ];
    });
    for (NSString *t in allows) {
        if ([title isEqualToString:t]) return YES;
    }
    return NO;
}

static BOOL ALNIsDenyTitle(NSString *title) {
    if (title.length == 0) return NO;
    static NSArray<NSString *> *denys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        denys = @[
            @"不允许", @"不允許", @"拒绝", @"拒絕", @"取消",
            @"Don't Allow", @"Don't Allow", @"Don't allow",
            @"Deny", @"Cancel", @"No"
        ];
    });
    for (NSString *t in denys) {
        if ([title isEqualToString:t]) return YES;
    }
    return NO;
}

#pragma mark - 1) Short-circuit authorization request

static void (*orig_requestAuthorization)(id, SEL, NSUInteger, id) = NULL;

static void aln_requestAuthorization(id self, SEL cmd, NSUInteger options, id completion) {
    ALNLog(@"requestAuthorization short-circuit options=%lu", (unsigned long)options);
    if (completion) {
        void (^handler)(BOOL, NSError *) = (void (^)(BOOL, NSError *))completion;
        dispatch_async(dispatch_get_main_queue(), ^{
            handler(YES, nil);
        });
    }
}

static BOOL installRequestAuthorizationHook(void) {
    Class cls = objc_getClass("UNUserNotificationCenter");
    if (!cls) {
        ALNLog(@"UNUserNotificationCenter missing");
        return NO;
    }
    SEL sel = sel_registerName("requestAuthorizationWithOptions:completionHandler:");
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        ALNLog(@"requestAuthorizationWithOptions: missing");
        return NO;
    }
    IMP prev = method_getImplementation(m);
    if (prev == (IMP)aln_requestAuthorization) return YES;
    orig_requestAuthorization = (void *)prev;
    method_setImplementation(m, (IMP)aln_requestAuthorization);
    ALNLog(@"hooked requestAuthorizationWithOptions:");
    return YES;
}

#pragma mark - 2) Report authorized settings

static NSInteger aln_ret2(id self, SEL cmd) { return 2; }

static BOOL patchInstanceIntGetter(Class cls, const char *selName) {
    if (!cls || !selName) return NO;
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    const char *enc = method_getTypeEncoding(m);
    if (!enc) return NO;
    IMP prev = method_getImplementation(m);
    if (prev == (IMP)aln_ret2) return YES;
    method_setImplementation(m, (IMP)aln_ret2);
    ALNLog(@"patched %s -%s => 2", class_getName(cls), selName);
    return YES;
}

static void installSettingsHooks(void) {
    Class cls = objc_getClass("UNNotificationSettings");
    if (!cls) return;

    const char *sels[] = {
        "authorizationStatus",
        "soundSetting",
        "badgeSetting",
        "alertSetting",
        "notificationCenterSetting",
        "lockScreenSetting",
        "criticalAlertSetting",
        "announcementSetting",
        "scheduledDeliverySetting",
        "timeSensitiveSetting",
        "directMessagesSetting",
        NULL
    };
    for (int i = 0; sels[i]; i++) {
        patchInstanceIntGetter(cls, sels[i]);
    }
}

#pragma mark - 3) Auto-tap Allow on remaining alerts

static void aln_autoTapAllow(UIAlertController *alert) {
    if (![alert isKindOfClass:[UIAlertController class]]) return;

    NSString *blob = [NSString stringWithFormat:@"%@\n%@", alert.title ?: @"", alert.message ?: @""];
    if (!ALNIsNotificationPromptText(blob)) return;

    static const void *kFlag = &kFlag;
    if (objc_getAssociatedObject(alert, kFlag)) return;
    objc_setAssociatedObject(alert, kFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIAlertAction *chosen = nil;
    for (UIAlertAction *action in alert.actions) {
        NSString *title = action.title ?: @"";
        if (ALNIsDenyTitle(title)) continue;
        if (ALNIsAllowTitle(title)) {
            chosen = action;
            break;
        }
        if (!chosen && action.style != UIAlertActionStyleCancel) {
            chosen = action;
        }
    }
    if (!chosen) return;

    UIAlertAction *actionToRun = chosen;
    __weak UIAlertController *weakAlert = alert;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIAlertController *strongAlert = weakAlert;
        if (!strongAlert) return;

        void (^handler)(UIAlertAction *) = nil;
        @try {
            handler = [actionToRun valueForKey:@"handler"];
        } @catch (__unused NSException *ex) {
            handler = nil;
        }

        ALNLog(@"auto-tap allow: %@", actionToRun.title ?: @"?");
        [strongAlert dismissViewControllerAnimated:NO completion:^{
            if (handler) handler(actionToRun);
        }];
    });
}

static void (*orig_viewWillAppear)(id, SEL, BOOL) = NULL;
static void (*orig_viewDidAppear)(id, SEL, BOOL) = NULL;

static void aln_viewWillAppear(id self, SEL cmd, BOOL animated) {
    if (orig_viewWillAppear) orig_viewWillAppear(self, cmd, animated);
    if ([self isKindOfClass:[UIAlertController class]]) {
        aln_autoTapAllow((UIAlertController *)self);
    }
}

static void aln_viewDidAppear(id self, SEL cmd, BOOL animated) {
    if (orig_viewDidAppear) orig_viewDidAppear(self, cmd, animated);
    if ([self isKindOfClass:[UIAlertController class]]) {
        aln_autoTapAllow((UIAlertController *)self);
    }
}

static BOOL hookInstance(Class cls, SEL sel, IMP neu, IMP *outOrig) {
    if (!cls || !sel || !neu) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NO;
    IMP prev = method_getImplementation(m);
    if (prev == neu) return YES;
    if (outOrig) *outOrig = prev;
    method_setImplementation(m, neu);
    return YES;
}

static void installAlertHooks(void) {
    Class cls = objc_getClass("UIAlertController");
    if (!cls) return;
    hookInstance(cls, @selector(viewWillAppear:), (IMP)aln_viewWillAppear, (IMP *)&orig_viewWillAppear);
    hookInstance(cls, @selector(viewDidAppear:), (IMP)aln_viewDidAppear, (IMP *)&orig_viewDidAppear);
    ALNLog(@"hooked UIAlertController appear");
}

#pragma mark - Entry

static void applyAll(const char *phase) {
    BOOL a = installRequestAuthorizationHook();
    installSettingsHooks();
    installAlertHooks();
    ALNLog(@"%s authHook=%d", phase, (int)a);
}

__attribute__((constructor))
static void AllowNotificationsInit(void) {
    @autoreleasepool {
        applyAll("constructor");

        dispatch_async(dispatch_get_main_queue(), ^{
            applyAll("main");
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            applyAll("delayed");
        });
    }
}
