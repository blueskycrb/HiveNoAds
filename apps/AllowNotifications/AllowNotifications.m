//
// AllowNotifications — auto-allow notification permission
//
// Delivered as Bootstrap/RootHide jailbreak tweak package:
//   com.blueskycrb.allownotifications-rootless (iphoneos-arm64e)
// Install:
//   /var/jb/Library/MobileSubstrate/DynamicLibraries/AllowNotifications.{dylib,plist}
//
// Automatically handles:
//   "xxx 想给你发送通知" / Would Like to Send You Notifications
//
// Pure Objective-C runtime hooks (no Substrate/Logos required at link time).
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
            @"想给你传送通知",
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

static NSString *ALNJoin(NSString *a, NSString *b) {
    return [NSString stringWithFormat:@"%@\n%@", a ?: @"", b ?: @""];
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
    ALNLog(@"patched %s", selName);
    return YES;
}

static void patchNotificationSettings(void) {
    Class cls = objc_getClass("UNNotificationSettings");
    if (!cls) {
        ALNLog(@"UNNotificationSettings missing");
        return;
    }
    // UNAuthorizationStatusAuthorized = 2; UNNotificationSettingEnabled = 2
    const char *sels[] = {
        "authorizationStatus",
        "soundSetting",
        "badgeSetting",
        "alertSetting",
        "notificationCenterSetting",
        "lockScreenSetting",
        "carPlaySetting",
        "criticalAlertSetting",
        "announcementSetting",
        "scheduledDeliverySetting",
        "timeSensitiveSetting",
        "directMessagesSetting",
        NULL
    };
    for (const char **p = sels; *p; p++) {
        patchInstanceIntGetter(cls, *p);
    }
}

#pragma mark - 3) Fallback auto-tap alerts

static void ALNAutoTapAllow(UIAlertController *alert) {
    if (![alert isKindOfClass:[UIAlertController class]]) return;

    NSString *blob = ALNJoin(alert.title, alert.message);
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

        [strongAlert dismissViewControllerAnimated:NO completion:^{
            if (handler) handler(actionToRun);
        }];
    });
}

static void (*orig_viewWillAppear)(id, SEL, BOOL) = NULL;
static void (*orig_viewDidAppear)(id, SEL, BOOL) = NULL;

static void aln_viewWillAppear(id self, SEL cmd, BOOL animated) {
    if (orig_viewWillAppear) orig_viewWillAppear(self, cmd, animated);
    else {
        struct objc_super superInfo = { self, class_getSuperclass(object_getClass(self)) };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&superInfo, cmd, animated);
    }
    if ([self isKindOfClass:[UIAlertController class]]) {
        ALNAutoTapAllow((UIAlertController *)self);
    }
}

static void aln_viewDidAppear(id self, SEL cmd, BOOL animated) {
    if (orig_viewDidAppear) orig_viewDidAppear(self, cmd, animated);
    else {
        struct objc_super superInfo = { self, class_getSuperclass(object_getClass(self)) };
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&superInfo, cmd, animated);
    }
    if ([self isKindOfClass:[UIAlertController class]]) {
        ALNAutoTapAllow((UIAlertController *)self);
    }
}

static BOOL installAlertControllerHooks(void) {
    Class cls = objc_getClass("UIAlertController");
    if (!cls) return NO;

    Method m1 = class_getInstanceMethod(cls, @selector(viewWillAppear:));
    Method m2 = class_getInstanceMethod(cls, @selector(viewDidAppear:));
    if (m1) {
        IMP prev = method_getImplementation(m1);
        if (prev != (IMP)aln_viewWillAppear) {
            orig_viewWillAppear = (void *)prev;
            method_setImplementation(m1, (IMP)aln_viewWillAppear);
        }
    }
    if (m2) {
        IMP prev = method_getImplementation(m2);
        if (prev != (IMP)aln_viewDidAppear) {
            orig_viewDidAppear = (void *)prev;
            method_setImplementation(m2, (IMP)aln_viewDidAppear);
        }
    }
    return YES;
}

#pragma mark - 4) SpringBoard system user-notification alert (optional)

static void ALNTryAcceptUserNotificationAlert(id selfObj) {
    if (!selfObj) return;

    NSString *header = nil;
    NSString *message = nil;
    @try { header = [selfObj valueForKey:@"alertHeader"]; } @catch (__unused NSException *e) {}
    @try { if (!header) header = [selfObj valueForKey:@"title"]; } @catch (__unused NSException *e) {}
    @try { message = [selfObj valueForKey:@"alertMessage"]; } @catch (__unused NSException *e) {}
    @try { if (!message) message = [selfObj valueForKey:@"message"]; } @catch (__unused NSException *e) {}

    NSString *blob = ALNJoin(header, message);
    if (!ALNIsNotificationPromptText(blob)) return;

    static const void *kSBFlag = &kSBFlag;
    if (objc_getAssociatedObject(selfObj, kSBFlag)) return;
    objc_setAssociatedObject(selfObj, kSBFlag, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    ALNLog(@"accept SBUserNotificationAlert: %@", blob);

    // Prefer default/OK button activation paths used by SpringBoard alerts.
    // Capture SELs as scalars so the block does not reference a stack array.
    SEL selDefault1 = sel_registerName("_defaultButtonPressed");
    SEL selDefault2 = sel_registerName("defaultButtonPressed");
    SEL selAccept1 = sel_registerName("_accept");
    SEL selAccept2 = sel_registerName("accept");
    SEL selButton = sel_registerName("_buttonPressed:");

    __weak id weakSelf = selfObj;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strong = weakSelf;
        if (!strong) return;

        SEL sels[5] = { selDefault1, selDefault2, selAccept1, selAccept2, selButton };
        for (NSUInteger i = 0; i < 5; i++) {
            SEL s = sels[i];
            if (![strong respondsToSelector:s]) continue;
            @try {
                if (s == selButton) {
                    ((void (*)(id, SEL, NSInteger))objc_msgSend)(strong, s, 0);
                } else {
                    ((void (*)(id, SEL))objc_msgSend)(strong, s);
                }
                return;
            } @catch (__unused NSException *ex) {
            }
        }
    });
}

static void (*orig_sb_willActivate)(id, SEL) = NULL;
static void (*orig_sb_didActivate)(id, SEL) = NULL;

static void aln_sb_willActivate(id self, SEL cmd) {
    if (orig_sb_willActivate) orig_sb_willActivate(self, cmd);
    ALNTryAcceptUserNotificationAlert(self);
}

static void aln_sb_didActivate(id self, SEL cmd) {
    if (orig_sb_didActivate) orig_sb_didActivate(self, cmd);
    ALNTryAcceptUserNotificationAlert(self);
}

static BOOL installSpringBoardAlertHooks(void) {
    Class cls = objc_getClass("SBUserNotificationAlert");
    if (!cls) {
        ALNLog(@"SBUserNotificationAlert not present in this process");
        return NO;
    }

    Method m1 = class_getInstanceMethod(cls, sel_registerName("willActivate"));
    Method m2 = class_getInstanceMethod(cls, sel_registerName("didActivate"));
    if (m1) {
        IMP prev = method_getImplementation(m1);
        if (prev != (IMP)aln_sb_willActivate) {
            orig_sb_willActivate = (void *)prev;
            method_setImplementation(m1, (IMP)aln_sb_willActivate);
        }
    }
    if (m2) {
        IMP prev = method_getImplementation(m2);
        if (prev != (IMP)aln_sb_didActivate) {
            orig_sb_didActivate = (void *)prev;
            method_setImplementation(m2, (IMP)aln_sb_didActivate);
        }
    }
    ALNLog(@"hooked SBUserNotificationAlert");
    return YES;
}

#pragma mark - ctor

__attribute__((constructor))
static void AllowNotificationsInit(void) {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"?";
        ALNLog(@"loaded in %@", bid);
        installRequestAuthorizationHook();
        patchNotificationSettings();
        installAlertControllerHooks();
        installSpringBoardAlertHooks();
    }
}