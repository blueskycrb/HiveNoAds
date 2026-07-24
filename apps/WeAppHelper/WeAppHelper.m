//
// WeAppHelper - crash-safe WeChat mini program helper
//
// Bootstrap / RootHide jailbreak tweak:
//   Package: com.blueskycrb.weapptool-rootless (iphoneos-arm64e)
//   Filter:  com.tencent.xin
//
// Target environment (verified design goals):
//   iOS 16.5.1 + WeChat 8.0.71
//
// Why the old "微信小程序助手" (com.25mao.weapptool) crashes:
//   1) Hooks MMServiceCenter defaultCenter globally
//   2) Hooks NewMainFrameViewController viewDidLoad at launch
//   3) Relies on old private table/plugin APIs
//   4) Debug MonkeyDev build + Dopamine /var/jb packaging
//
// This rewrite intentionally:
//   - Never hooks MMServiceCenter / NewMainFrameViewController
//   - Checks class/selector existence before every hook
//   - Uses plain UIKit settings page (no WCTableViewManager dependency)
//   - Resolves services via MMContext first, MMServiceCenter fallback
//   - Wraps private API calls in @try/@catch
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Logging

static const BOOL kWAHVerbose = NO;
#define WAHLog(fmt, ...) do { if (kWAHVerbose) NSLog(@"[WeAppHelper] " fmt, ##__VA_ARGS__); } while (0)

#pragma mark - Defaults keys

static NSString * const kWAHEnabledKey = @"WAH.Enabled";
static NSString * const kWAHDebugKey   = @"WAH.DebugVConsole";
static NSString * const kWAHJumpKey    = @"WAH.JumpWxa";
static NSString * const kWAHCustomKey  = @"WAH.CustomIDEnabled";
static NSString * const kWAHCustomID   = @"WAH.CustomIDString";

#pragma mark - Config

static NSUserDefaults *WAHDefaults(void) {
    return [NSUserDefaults standardUserDefaults];
}

static BOOL WAHBool(NSString *key, BOOL fallback) {
    NSUserDefaults *ud = WAHDefaults();
    if ([ud objectForKey:key] == nil) return fallback;
    return [ud boolForKey:key];
}

static void WAHSetBool(NSString *key, BOOL value) {
    [WAHDefaults() setBool:value forKey:key];
    [WAHDefaults() synchronize];
}

static NSString *WAHString(NSString *key) {
    NSString *s = [WAHDefaults() stringForKey:key];
    return s ?: @"";
}

static void WAHSetString(NSString *key, NSString *value) {
    [WAHDefaults() setObject:(value ?: @"") forKey:key];
    [WAHDefaults() synchronize];
}

static BOOL WAHPluginEnabled(void) { return WAHBool(kWAHEnabledKey, YES); }
static BOOL WAHDebugEnabled(void)  { return WAHPluginEnabled() && WAHBool(kWAHDebugKey, YES); }
static BOOL WAHJumpEnabled(void)   { return WAHPluginEnabled() && WAHBool(kWAHJumpKey, YES); }
static BOOL WAHCustomEnabled(void) { return WAHPluginEnabled() && WAHBool(kWAHCustomKey, NO); }

#pragma mark - Runtime helpers

static BOOL WAHClassHasOwnInstanceMethod(Class cls, SEL sel) {
    if (!cls || !sel) return NO;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == sel) {
            found = YES;
            break;
        }
    }
    if (methods) free(methods);
    return found;
}

// Hook only the target class. Never replace a superclass implementation in-place.
static BOOL WAHHookInstance(Class cls, SEL sel, IMP newImp, IMP *outOrig) {
    if (!cls || !sel || !newImp) return NO;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        WAHLog("skip missing -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
        return NO;
    }
    IMP orig = method_getImplementation(m);
    if (outOrig) *outOrig = orig;
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;

    if (WAHClassHasOwnInstanceMethod(cls, sel)) {
        method_setImplementation(class_getInstanceMethod(cls, sel), newImp);
    } else {
        // Add an override on this class; orig IMP remains the inherited implementation.
        if (!class_addMethod(cls, sel, newImp, types)) {
            method_setImplementation(class_getInstanceMethod(cls, sel), newImp);
        }
    }
    WAHLog("hooked -[%@ %@]", NSStringFromClass(cls), NSStringFromSelector(sel));
    return YES;
}

static id WAHSafeMsg0(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    @try {
        return ((id(*)(id, SEL))objc_msgSend)(obj, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static id WAHSafeMsg1(id obj, SEL sel, id a) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    @try {
        return ((id(*)(id, SEL, id))objc_msgSend)(obj, sel, a);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

#pragma mark - Service lookup (no hooks)

static id WAHGetService(Class serviceClass) {
    if (!serviceClass) return nil;
    @try {
        Class MMContext = NSClassFromString(@"MMContext");
        if (MMContext) {
            SEL currentSel = sel_registerName("currentContext");
            if ([MMContext respondsToSelector:currentSel]) {
                id ctx = ((id(*)(id, SEL))objc_msgSend)(MMContext, currentSel);
                if (ctx) {
                    SEL getService = sel_registerName("getService:");
                    if ([ctx respondsToSelector:getService]) {
                        id svc = ((id(*)(id, SEL, Class))objc_msgSend)(ctx, getService, serviceClass);
                        if (svc) return svc;
                    }
                }
            }
            // Some builds use +activeUserContext / +mainContext
            const char *ctxSels[] = {"activeUserContext", "mainContext", "sharedContext"};
            for (size_t si = 0; si < sizeof(ctxSels) / sizeof(ctxSels[0]); si++) {
                SEL s = sel_registerName(ctxSels[si]);
                if ([MMContext respondsToSelector:s]) {
                    id ctx = ((id(*)(id, SEL))objc_msgSend)(MMContext, s);
                    SEL getService = sel_registerName("getService:");
                    if (ctx && [ctx respondsToSelector:getService]) {
                        id svc = ((id(*)(id, SEL, Class))objc_msgSend)(ctx, getService, serviceClass);
                        if (svc) return svc;
                    }
                }
            }
        }

        Class MSC = NSClassFromString(@"MMServiceCenter");
        if (MSC) {
            SEL def = sel_registerName("defaultCenter");
            if ([MSC respondsToSelector:def]) {
                id center = ((id(*)(id, SEL))objc_msgSend)(MSC, def);
                SEL getService = sel_registerName("getService:");
                if (center && [center respondsToSelector:getService]) {
                    return ((id(*)(id, SEL, Class))objc_msgSend)(center, getService, serviceClass);
                }
            }
        }
    } @catch (__unused NSException *e) {
        WAHLog("getService exception");
    }
    return nil;
}

#pragma mark - Toast helpers

static void WAHToast(NSString *text) {
    if (text.length == 0) return;
    @try {
        Class toastCls = NSClassFromString(@"MMToastViewController");
        if (toastCls) {
            id toast = [toastCls new];
            SEL sel = sel_registerName("showDoneToastWithText:");
            if ([toast respondsToSelector:sel]) {
                ((void(*)(id, SEL, id))objc_msgSend)(toast, sel, text);
                return;
            }
            sel = sel_registerName("showSaveResultTip:andText:andDelegate:");
            if ([toast respondsToSelector:sel]) {
                ((void(*)(id, SEL, id, id, id))objc_msgSend)(toast, sel, nil, text, nil);
                return;
            }
        }
    } @catch (__unused NSException *e) {}

    // Fallback: brief UIAlertController auto-dismiss
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = nil;
        UIWindow *window = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
        if (!window) window = [UIApplication sharedApplication].keyWindow;
        top = window.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if (!top) return;
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:nil message:text preferredStyle:UIAlertControllerStyleAlert];
        [top presentViewController:ac animated:YES completion:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [ac dismissViewControllerAnimated:YES completion:nil];
            });
        }];
    });
}

#pragma mark - Open mini program

static BOOL WAHOpenMiniProgram(NSString *userName, NSString *path) {
    if (userName.length == 0) return NO;
    @try {
        Class Param = NSClassFromString(@"WAAppOpenParameter");
        if (!Param) {
            WAHToast(@"当前微信缺少 WAAppOpenParameter");
            return NO;
        }

        id param = nil;
        SEL initSel = sel_registerName("initWithWeAppUsername:");
        if ([Param instancesRespondToSelector:initSel]) {
            param = ((id(*)(id, SEL, id))objc_msgSend)([Param alloc], initSel, userName);
        } else {
            param = [Param new];
            SEL setUser = sel_registerName("setM_nsUserName:");
            if ([param respondsToSelector:setUser]) {
                ((void(*)(id, SEL, id))objc_msgSend)(param, setUser, userName);
            } else {
                SEL setUser2 = sel_registerName("setUsername:");
                if ([param respondsToSelector:setUser2]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(param, setUser2, userName);
                }
            }
        }
        if (!param) return NO;

        if (path.length > 0) {
            SEL setPath = sel_registerName("setM_nsPagePath:");
            if ([param respondsToSelector:setPath]) {
                ((void(*)(id, SEL, id))objc_msgSend)(param, setPath, path);
            } else {
                SEL setPath2 = sel_registerName("setPagePath:");
                if ([param respondsToSelector:setPath2]) {
                    ((void(*)(id, SEL, id))objc_msgSend)(param, setPath2, path);
                }
            }
        }

        // scene often required; 1001 is common for discovery-like open
        SEL setScene = sel_registerName("setM_uiScene:");
        if ([param respondsToSelector:setScene]) {
            ((void(*)(id, SEL, unsigned int))objc_msgSend)(param, setScene, 1001);
        }

        Class Loader = NSClassFromString(@"WAAppContactPreLoader");
        id loader = WAHGetService(Loader);
        if (!loader) {
            WAHToast(@"无法获取 WAAppContactPreLoader");
            return NO;
        }

        SEL open4 = sel_registerName("openApp:taskExtInfo:onSuccess:onFailed:");
        if ([loader respondsToSelector:open4]) {
            void (^ok)(void) = ^{ WAHToast(@"已打开小程序"); };
            void (^fail)(void) = ^{ WAHToast(@"打开小程序失败"); };
            ((void(*)(id, SEL, id, id, id, id))objc_msgSend)(loader, open4, param, nil, ok, fail);
            return YES;
        }

        SEL open3 = sel_registerName("openApp:taskExtInfo:handlerWrapper:");
        if ([loader respondsToSelector:open3]) {
            ((void(*)(id, SEL, id, id, id))objc_msgSend)(loader, open3, param, nil, nil);
            return YES;
        }

        WAHToast(@"当前微信 openApp API 不兼容");
        return NO;
    } @catch (NSException *e) {
        WAHLog("open exception: %@", e);
        WAHToast(@"打开小程序异常");
        return NO;
    }
}

#pragma mark - Settings UI (plain UIKit)

@interface WAHSettingViewController : UITableViewController <UITextFieldDelegate>
@end

@implementation WAHSettingViewController {
    UISwitch *_enabledSwitch;
    UISwitch *_debugSwitch;
    UISwitch *_jumpSwitch;
    UISwitch *_customSwitch;
    UITextField *_customField;
    UITextField *_userNameField;
    UITextField *_pathField;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        self.title = @"小程序助手";
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"完成"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(wah_close)];
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)wah_close {
    [self.navigationController popViewControllerAnimated:YES];
    if (self.presentingViewController && self.navigationController.viewControllers.firstObject == self) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (UISwitch *)wah_switch:(BOOL)on action:(SEL)action {
    UISwitch *s = [[UISwitch alloc] init];
    s.on = on;
    [s addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return s;
}

- (UITextField *)wah_field:(NSString *)placeholder text:(NSString *)text {
    UITextField *tf = [[UITextField alloc] init];
    tf.placeholder = placeholder;
    tf.text = text;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    tf.font = [UIFont systemFontOfSize:15];
    tf.delegate = self;
    return tf;
}

#pragma mark UITableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1;
    if (section == 1) return 3;
    if (section == 2) return 1;
    if (section == 3) return 3;
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return @"总开关";
    if (section == 1) return @"功能";
    if (section == 2) return @"自定义 AppId（跳转改写）";
    if (section == 3) return @"打开小程序";
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"兼容 iOS 16.5.1 / 微信 8.0.71。已移除旧版会闪退的 MMServiceCenter 与主界面 hook。";
    }
    if (section == 1) {
        return @"开启调试后，小程序内可使用 vConsole。";
    }
    if (section == 3) {
        return @"userName 一般为 gh_ 开头原始 ID；path 可留空。";
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"wah.cell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
    }
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.text = nil;
    cell.textLabel.numberOfLines = 1;

    // clear previous contentView textfields
    for (UIView *v in cell.contentView.subviews) {
        if ([v isKindOfClass:[UITextField class]]) [v removeFromSuperview];
    }

    if (indexPath.section == 0) {
        cell.textLabel.text = @"启用小程序助手";
        if (!_enabledSwitch) _enabledSwitch = [self wah_switch:WAHPluginEnabled() action:@selector(onEnabled:)];
        _enabledSwitch.on = WAHPluginEnabled();
        cell.accessoryView = _enabledSwitch;
        return cell;
    }

    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"强制开启调试 / vConsole";
            if (!_debugSwitch) _debugSwitch = [self wah_switch:WAHBool(kWAHDebugKey, YES) action:@selector(onDebug:)];
            _debugSwitch.on = WAHBool(kWAHDebugKey, YES);
            cell.accessoryView = _debugSwitch;
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"增强 jumpWxa 跳转";
            if (!_jumpSwitch) _jumpSwitch = [self wah_switch:WAHBool(kWAHJumpKey, YES) action:@selector(onJump:)];
            _jumpSwitch.on = WAHBool(kWAHJumpKey, YES);
            cell.accessoryView = _jumpSwitch;
        } else {
            cell.textLabel.text = @"自定义 AppId 改写";
            if (!_customSwitch) _customSwitch = [self wah_switch:WAHBool(kWAHCustomKey, NO) action:@selector(onCustom:)];
            _customSwitch.on = WAHBool(kWAHCustomKey, NO);
            cell.accessoryView = _customSwitch;
        }
        return cell;
    }

    if (indexPath.section == 2) {
        if (!_customField) _customField = [self wah_field:@"wx 开头的 appid" text:WAHString(kWAHCustomID)];
        _customField.frame = CGRectMake(16, 0, tableView.bounds.size.width - 64, 44);
        _customField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [cell.contentView addSubview:_customField];
        return cell;
    }

    if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            if (!_userNameField) _userNameField = [self wah_field:@"小程序 userName (gh_...)" text:@""];
            _userNameField.frame = CGRectMake(16, 0, tableView.bounds.size.width - 64, 44);
            _userNameField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [cell.contentView addSubview:_userNameField];
        } else if (indexPath.row == 1) {
            if (!_pathField) _pathField = [self wah_field:@"页面 path（可选）" text:@""];
            _pathField.frame = CGRectMake(16, 0, tableView.bounds.size.width - 64, 44);
            _pathField.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            [cell.contentView addSubview:_pathField];
        } else {
            cell.textLabel.text = @"立即打开";
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        return cell;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 3 && indexPath.row == 2) {
        [self.view endEditing:YES];
        NSString *user = [_userNameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *path = [_pathField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (user.length == 0) {
            WAHToast(@"请输入 userName");
            return;
        }
        WAHOpenMiniProgram(user, path);
    }
}

- (void)onEnabled:(UISwitch *)s { WAHSetBool(kWAHEnabledKey, s.on); }
- (void)onDebug:(UISwitch *)s   { WAHSetBool(kWAHDebugKey, s.on); }
- (void)onJump:(UISwitch *)s    { WAHSetBool(kWAHJumpKey, s.on); }
- (void)onCustom:(UISwitch *)s  { WAHSetBool(kWAHCustomKey, s.on); }

- (void)textFieldDidEndEditing:(UITextField *)textField {
    if (textField == _customField) {
        WAHSetString(kWAHCustomID, textField.text ?: @"");
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end

#pragma mark - Hook: force vConsole / debug

static BOOL (*WAH_orig_isOpenDebugAndVConsole)(id, SEL) = NULL;
static BOOL WAH_repl_isOpenDebugAndVConsole(id self, SEL _cmd) {
    if (WAHDebugEnabled()) {
        return YES;
    }
    if (WAH_orig_isOpenDebugAndVConsole) {
        return WAH_orig_isOpenDebugAndVConsole(self, _cmd);
    }
    return NO;
}

#pragma mark - Hook: settings entry

static void WAHPushSettings(UIViewController *from) {
    if (!from) return;
    WAHSettingViewController *vc = [[WAHSettingViewController alloc] init];
    if (from.navigationController) {
        [from.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [from presentViewController:nav animated:YES completion:nil];
    }
}

// Lightweight target for bar button (avoids UIAction / weak-target pitfalls).
@interface WAHBarTarget : NSObject
@property (nonatomic, weak) UIViewController *host;
- (void)open;
@end
@implementation WAHBarTarget
- (void)open { WAHPushSettings(self.host); }
@end

static char kWAHBarTargetKey;

// Prefer adding a button on NewSettingViewController navigation bar (very stable).
static void (*WAH_orig_setting_viewDidAppear)(id, SEL, BOOL) = NULL;
static void WAH_repl_setting_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (WAH_orig_setting_viewDidAppear) {
        WAH_orig_setting_viewDidAppear(self, _cmd, animated);
    }
    @try {
        UIViewController *vc = (UIViewController *)self;
        if (![vc isKindOfClass:[UIViewController class]]) return;

        for (UIBarButtonItem *item in vc.navigationItem.rightBarButtonItems ?: @[]) {
            if (item.tag == 0x57414831) return; // already added
        }

        WAHBarTarget *target = [[WAHBarTarget alloc] init];
        target.host = vc;
        objc_setAssociatedObject(vc, &kWAHBarTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UIBarButtonItem *btn = [[UIBarButtonItem alloc] initWithTitle:@"小程序"
                                                                style:UIBarButtonItemStylePlain
                                                               target:target
                                                               action:@selector(open)];
        btn.tag = 0x57414831;

        NSMutableArray *items = [NSMutableArray arrayWithArray:vc.navigationItem.rightBarButtonItems ?: @[]];
        [items insertObject:btn atIndex:0];
        vc.navigationItem.rightBarButtonItems = items;
    } @catch (__unused NSException *e) {
        WAHLog("settings bar inject failed");
    }
}


// Secondary entry: intercept willAppear and add no table mutation (bar only already enough).
// Also support WCPluginsMgr registration if present (non-fatal).
static void WAHTryRegisterPlugin(void) {
    @try {
        Class mgrCls = NSClassFromString(@"WCPluginsMgr");
        if (!mgrCls) return;
        SEL shared = sel_registerName("sharedInstance");
        id mgr = nil;
        if ([mgrCls respondsToSelector:shared]) {
            mgr = ((id(*)(id, SEL))objc_msgSend)(mgrCls, shared);
        } else {
            SEL def = sel_registerName("defaultMgr");
            if ([mgrCls respondsToSelector:def]) {
                mgr = ((id(*)(id, SEL))objc_msgSend)(mgrCls, def);
            }
        }
        if (!mgr) return;
        SEL reg = sel_registerName("registerControllerWithTitle:version:controller:");
        if (![mgr respondsToSelector:reg]) return;
        ((void(*)(id, SEL, id, id, id))objc_msgSend)(mgr, reg, @"小程序助手", @"1.0.0", @"WAHSettingViewController");
    } @catch (__unused NSException *e) {}
}

#pragma mark - Hook: jumpWxa custom appid rewrite

static void (*WAH_orig_internalHandleJump)(id, SEL, id, id, id) = NULL;
static void WAH_repl_internalHandleJump(id self, SEL _cmd, id url, id translateInfo, id parentVC) {
    @try {
        if (WAHJumpEnabled() && WAHCustomEnabled()) {
            NSString *custom = [WAHString(kWAHCustomID) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (custom.length > 0) {
                // url may be NSString or NSURL
                NSString *urlString = nil;
                if ([url isKindOfClass:[NSURL class]]) {
                    urlString = [(NSURL *)url absoluteString];
                } else if ([url isKindOfClass:[NSString class]]) {
                    urlString = (NSString *)url;
                }
                if ([urlString containsString:@"jumpWxa"] || [urlString containsString:@"jumpwxa"]) {
                    // Rewrite appid query if present
                    NSURLComponents *comp = [NSURLComponents componentsWithString:urlString];
                    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray arrayWithArray:comp.queryItems ?: @[]];
                    BOOL replaced = NO;
                    for (NSInteger i = 0; i < (NSInteger)items.count; i++) {
                        NSURLQueryItem *it = items[i];
                        NSString *name = it.name.lowercaseString;
                        if ([name isEqualToString:@"appid"] || [name isEqualToString:@"appId".lowercaseString]) {
                            items[i] = [NSURLQueryItem queryItemWithName:it.name value:custom];
                            replaced = YES;
                        }
                    }
                    // weixin://app/<appid>/jumpWxa/...
                    NSString *rewritten = urlString;
                    if (!replaced) {
                        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"weixin://app/([^/]+)/jumpWxa"
                                                                                           options:NSRegularExpressionCaseInsensitive
                                                                                             error:nil];
                        if (re) {
                            rewritten = [re stringByReplacingMatchesInString:urlString
                                                                     options:0
                                                                       range:NSMakeRange(0, urlString.length)
                                                                withTemplate:[NSString stringWithFormat:@"weixin://app/%@/jumpWxa", custom]];
                        }
                    } else {
                        comp.queryItems = items;
                        rewritten = comp.string ?: urlString;
                    }
                    if (rewritten.length && ![rewritten isEqualToString:urlString]) {
                        if ([url isKindOfClass:[NSURL class]]) {
                            url = [NSURL URLWithString:rewritten] ?: url;
                        } else {
                            url = rewritten;
                        }
                        WAHLog("rewrote jump url -> %@", rewritten);
                    }
                }
            }
        }
    } @catch (__unused NSException *e) {
        WAHLog("jump rewrite exception");
    }

    if (WAH_orig_internalHandleJump) {
        @try {
            WAH_orig_internalHandleJump(self, _cmd, url, translateInfo, parentVC);
        } @catch (__unused NSException *e) {
            WAHLog("orig internalHandleJump exception");
        }
    }
}

#pragma mark - Install hooks

static void WAHInstallHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 1) Force debug / vConsole
        Class waWeb = NSClassFromString(@"WAWebViewController");
        if (waWeb) {
            WAHHookInstance(waWeb,
                            sel_registerName("isOpenDebugAndVConsole"),
                            (IMP)WAH_repl_isOpenDebugAndVConsole,
                            (IMP *)&WAH_orig_isOpenDebugAndVConsole);
        }

        // 2) Settings entry on WeChat settings page only (no main-frame hooks)
        Class setting = NSClassFromString(@"NewSettingViewController");
        if (setting) {
            SEL appear = @selector(viewDidAppear:);
            if ([setting instancesRespondToSelector:appear]) {
                WAHHookInstance(setting,
                                appear,
                                (IMP)WAH_repl_setting_viewDidAppear,
                                (IMP *)&WAH_orig_setting_viewDidAppear);
            }
        }

        // 3) jumpWxa handling
        Class jumpMgr = NSClassFromString(@"WCBusinessJumpMgr");
        if (jumpMgr) {
            SEL jumpSel = sel_registerName("internalHandleJump:translateInfo:parentViewController:");
            if ([jumpMgr instancesRespondToSelector:jumpSel]) {
                WAHHookInstance(jumpMgr,
                                jumpSel,
                                (IMP)WAH_repl_internalHandleJump,
                                (IMP *)&WAH_orig_internalHandleJump);
            }
        }

        WAHTryRegisterPlugin();
        WAHLog("hooks installed");
    });
}

__attribute__((constructor))
static void WeAppHelperInit(void) {
    @autoreleasepool {
        // Delay slightly so WeChat classes are loaded.
        dispatch_async(dispatch_get_main_queue(), ^{
            WAHInstallHooks();
        });
        // Backup install after a short delay for late-loaded classes.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WAHInstallHooks();
        });
    }
}


