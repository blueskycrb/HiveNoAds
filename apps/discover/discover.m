//
// discover.dylib — 小红书图片保存/下载 (TrollFools / Substrate / ElleKit)
// Bundle: com.xingin.discover | 进程: discover | 对照版本: 9.38.1
//
// 用法:
//   越狱 Substrate: 放进 DynamicLibraries + plist
//   TrollFools: 注入到小红书 App
//   打开笔记 → 点右侧红色 ↓ → 保存到相册
//   或双指长按图片区域
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>
#import <unistd.h>

#define XHSLog(fmt, ...) NSLog(@"[XHSImageSave] " fmt, ##__VA_ARGS__)

#pragma mark - Auth / Photos

static void XHSAuthThen(void (^block)(BOOL granted)) {
    void (^finish)(PHAuthorizationStatus) = ^(PHAuthorizationStatus st) {
        BOOL g = (st == PHAuthorizationStatusAuthorized);
        if (@available(iOS 14, *)) g = g || (st == PHAuthorizationStatusLimited);
        dispatch_async(dispatch_get_main_queue(), ^{ if (block) block(g); });
    };
    if (@available(iOS 14, *)) {
        PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        if (st == PHAuthorizationStatusNotDetermined)
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:finish];
        else
            finish(st);
    } else {
        PHAuthorizationStatus st = [PHPhotoLibrary authorizationStatus];
        if (st == PHAuthorizationStatusNotDetermined)
            [PHPhotoLibrary requestAuthorization:finish];
        else
            finish(st);
    }
}

static void XHSSaveImage(UIImage *image, void (^done)(BOOL, NSError *)) {
    if (!image) {
        if (done) done(NO, [NSError errorWithDomain:@"XHSImageSave" code:1
                              userInfo:@{NSLocalizedDescriptionKey: @"nil image"}]);
        return;
    }
    XHSAuthThen(^(BOOL granted) {
        if (!granted) {
            if (done) done(NO, [NSError errorWithDomain:@"XHSImageSave" code:2
                                  userInfo:@{NSLocalizedDescriptionKey: @"相册权限未开"}]);
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImage:image];
        } completionHandler:^(BOOL success, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(success, error); });
        }];
    });
}

static void XHSSaveData(NSData *data, void (^done)(BOOL, NSError *)) {
    if (data.length < 32) {
        if (done) done(NO, [NSError errorWithDomain:@"XHSImageSave" code:3
                              userInfo:@{NSLocalizedDescriptionKey: @"empty data"}]);
        return;
    }
    UIImage *img = [UIImage imageWithData:data];
    if (img) { XHSSaveImage(img, done); return; }
    XHSAuthThen(^(BOOL granted) {
        if (!granted) {
            if (done) done(NO, [NSError errorWithDomain:@"XHSImageSave" code:2
                                  userInfo:@{NSLocalizedDescriptionKey: @"相册权限未开"}]);
            return;
        }
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"xhs_%@.img", NSUUID.UUID.UUIDString]];
        if (![data writeToFile:path atomically:YES]) {
            if (done) done(NO, [NSError errorWithDomain:@"XHSImageSave" code:4
                                  userInfo:@{NSLocalizedDescriptionKey: @"write tmp fail"}]);
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:[NSURL fileURLWithPath:path]];
        } completionHandler:^(BOOL success, NSError *error) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(success, error); });
        }];
    });
}

static UIWindow *XHSKeyWindow(void) {
    UIWindow *win = UIApplication.sharedApplication.keyWindow;
    if (win) return win;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)sc;
        for (UIWindow *w in ws.windows) if (w.isKeyWindow) return w;
        if (ws.windows.count) return ws.windows.firstObject;
    }
    return nil;
}

static void XHSToast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = XHSKeyWindow();
        if (!win) return;
        UILabel *lab = [UILabel new];
        lab.text = msg;
        lab.textColor = UIColor.whiteColor;
        lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
        lab.font = [UIFont boldSystemFontOfSize:14];
        lab.textAlignment = NSTextAlignmentCenter;
        lab.numberOfLines = 0;
        lab.layer.cornerRadius = 10;
        lab.clipsToBounds = YES;
        CGSize fit = [lab sizeThatFits:CGSizeMake(win.bounds.size.width - 72, 160)];
        lab.frame = CGRectMake(0, 0, fit.width + 28, fit.height + 16);
        lab.center = CGPointMake(CGRectGetMidX(win.bounds), win.bounds.size.height * 0.8);
        [win addSubview:lab];
        [UIView animateWithDuration:0.2 delay:1.6 options:0 animations:^{ lab.alpha = 0; }
                         completion:^(__unused BOOL f) { [lab removeFromSuperview]; }];
    });
}

#pragma mark - URL collect / download

static BOOL XHSIsImageURL(NSString *s) {
    if (s.length < 12) return NO;
    NSString *l = s.lowercaseString;
    if (![l hasPrefix:@"http"]) return NO;
    return [l containsString:@"xhscdn"] ||
           [l containsString:@"xiaohongshu"] ||
           [l containsString:@"sns-img"] ||
           [l containsString:@".jpg"] ||
           [l containsString:@".jpeg"] ||
           [l containsString:@".png"] ||
           [l containsString:@".webp"] ||
           [l containsString:@".heic"] ||
           [l containsString:@"fmt=jpeg"] ||
           [l containsString:@"fmt=png"] ||
           [l containsString:@"fmt=webp"] ||
           [l containsString:@"/image"];
}

static void XHSCollect(id obj, NSMutableSet<NSString *> *out, NSInteger depth) {
    if (!obj || depth > 5) return;
    if ([obj isKindOfClass:[NSString class]]) {
        if (XHSIsImageURL((NSString *)obj)) [out addObject:(NSString *)obj];
        return;
    }
    if ([obj isKindOfClass:[NSURL class]]) {
        NSString *s = [(NSURL *)obj absoluteString];
        if (XHSIsImageURL(s)) [out addObject:s];
        return;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        for (id x in (NSArray *)obj) XHSCollect(x, out, depth + 1);
        return;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)obj enumerateKeysAndObjectsUsingBlock:^(__unused id k, id v, __unused BOOL *s) {
            XHSCollect(v, out, depth + 1);
        }];
        return;
    }
    static NSArray<NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @[
            @"url", @"urlString", @"imageUrl", @"imageURL", @"image_url",
            @"originUrl", @"originalUrl", @"origin_url", @"original_url",
            @"url_size_large", @"url_default", @"urlDefault", @"urlSizeLarge",
            @"largeUrl", @"veryLargeImageUrl", @"originImageUrl", @"originImgUrl",
            @"info_list", @"infoList", @"urlInfoList", @"url_info_list",
            @"originImgInfo", @"imageInfo", @"image_list", @"url_multi",
            @"livePhotoUrl", @"live_photo_url"
        ];
    });
    for (NSString *k in keys) {
        @try {
            if (![obj respondsToSelector:NSSelectorFromString(k)]) continue;
            XHSCollect([obj valueForKey:k], out, depth + 1);
        } @catch (__unused NSException *e) {}
    }
}

static NSInteger XHSURLScore(NSString *u) {
    NSString *l = u.lowercaseString;
    NSInteger s = (NSInteger)u.length / 40;
    if ([l containsString:@"origin"] || [l containsString:@"original"]) s += 12;
    if ([l containsString:@"url_size_large"] || [l containsString:@"size_large"]) s += 10;
    if ([l containsString:@"large"] || [l containsString:@"1080"] || [l containsString:@"1440"]) s += 5;
    if ([l containsString:@"thumb"] || [l containsString:@"avatar"] || [l containsString:@"icon"]) s -= 20;
    return s;
}

static void XHSDownloadAndSave(NSString *urlString) {
    if (!urlString.length) return;
    XHSLog(@"GET %@", urlString);
    XHSToast(@"正在下载图片…");
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { XHSToast(@"URL 无效"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:30];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.xiaohongshu.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"image/avif,image/webp,image/apng,image/*,*/*;q=0.8" forHTTPHeaderField:@"Accept"];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.HTTPShouldSetCookies = YES;
    cfg.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        XHSLog(@"resp %ld bytes=%lu err=%@", (long)http.statusCode, (unsigned long)data.length, err);
        if (err || data.length < 64) {
            XHSToast([NSString stringWithFormat:@"下载失败: %@", err.localizedDescription ?: @"empty"]);
            return;
        }
        XHSSaveData(data, ^(BOOL ok, NSError *e) {
            XHSToast(ok ? @"✅ 已保存到相册" :
                     [NSString stringWithFormat:@"保存失败: %@", e.localizedDescription ?: @"?"]);
        });
    }] resume];
}

static void XHSForceSaveFromView(UIView *view) {
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    UIView *v = view;
    for (int i = 0; i < 10 && v; i++, v = v.superview) {
        for (NSString *k in @[@"imageURL", @"imageUrl", @"url", @"currentImageURL",
                              @"sd_imageURL", @"yy_imageURL", @"model", @"viewModel",
                              @"note", @"imageInfo", @"noteImage", @"data", @"item", @"media"]) {
            @try {
                if (![v respondsToSelector:NSSelectorFromString(k)]) continue;
                XHSCollect([v valueForKey:k], set, 0);
            } @catch (__unused NSException *e) {}
        }
    }

    if (set.count) {
        NSArray *sorted = [set.allObjects sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            NSInteger sa = XHSURLScore(a), sb = XHSURLScore(b);
            if (sa > sb) return NSOrderedAscending;
            if (sa < sb) return NSOrderedDescending;
            return NSOrderedSame;
        }];
        XHSLog(@"picked %@", sorted.firstObject);
        XHSDownloadAndSave(sorted.firstObject);
        return;
    }

    v = view;
    for (int i = 0; i < 12 && v; i++, v = v.superview) {
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImage *img = ((UIImageView *)v).image;
            if (img.size.width > 48 && img.size.height > 48) {
                XHSSaveImage(img, ^(BOOL ok, NSError *e) {
                    XHSToast(ok ? @"✅ 已从当前画面保存" :
                             [NSString stringWithFormat:@"保存失败: %@", e.localizedDescription ?: @"?"]);
                });
                return;
            }
        }
    }

    if (view && view.bounds.size.width > 48) {
        if (@available(iOS 10.0, *)) {
            UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:view.bounds.size];
            UIImage *snap = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
            }];
            if (snap) {
                XHSSaveImage(snap, ^(BOOL ok, NSError *e) {
                    XHSToast(ok ? @"✅ 已截取视图保存(非原图)" :
                             [NSString stringWithFormat:@"保存失败: %@", e.localizedDescription ?: @"?"]);
                });
                return;
            }
        }
    }
    XHSToast(@"未找到可保存的图片");
}

#pragma mark - Floating UI

@interface XHSFloatUI : NSObject
+ (void)install;
@end

@implementation XHSFloatUI

+ (void)install {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        __block void (^tryAttach)(void) = nil;
        tryAttach = ^{
            UIWindow *win = XHSKeyWindow();
            if (!win) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), tryAttach);
                return;
            }
            [self attachToWindow:win];
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), tryAttach);
    });
}

+ (void)attachToWindow:(UIWindow *)win {
    if (objc_getAssociatedObject(win, _cmd)) return;
    objc_setAssociatedObject(win, _cmd, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGFloat w = win.bounds.size.width, h = win.bounds.size.height;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(w - 62, h * 0.52, 50, 50);
    btn.backgroundColor = [[UIColor colorWithRed:1 green:0.2 blue:0.35 alpha:1] colorWithAlphaComponent:0.9];
    btn.layer.cornerRadius = 25;
    btn.layer.shadowColor = UIColor.blackColor.CGColor;
    btn.layer.shadowOpacity = 0.35;
    btn.layer.shadowRadius = 4;
    btn.layer.shadowOffset = CGSizeMake(0, 2);
    [btn setTitle:@"↓" forState:UIControlStateNormal];
    [btn setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:24 weight:UIFontWeightBold];
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                           UIViewAutoresizingFlexibleTopMargin |
                           UIViewAutoresizingFlexibleBottomMargin;
    [btn addTarget:self action:@selector(tap:) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    [btn addGestureRecognizer:pan];
    [win addSubview:btn];

    UILongPressGestureRecognizer *lp =
        [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(twoFinger:)];
    lp.numberOfTouchesRequired = 2;
    lp.minimumPressDuration = 0.4;
    [win addGestureRecognizer:lp];

    XHSLog(@"float button ready");
    XHSToast(@"图片保存插件已加载");
}

+ (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    CGPoint t = [g translationInView:v.superview];
    v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
    [g setTranslation:CGPointZero inView:v.superview];
}

+ (void)tap:(UIButton *)sender {
    UIWindow *win = sender.window ?: XHSKeyWindow();
    if (!win) return;
    CGPoint c = CGPointMake(CGRectGetMidX(win.bounds), CGRectGetMidY(win.bounds) - 60);
    UIView *hit = [win hitTest:c withEvent:nil] ?: win;
    UIView *img = hit;
    while (img && ![img isKindOfClass:[UIImageView class]]) img = img.superview;
    XHSForceSaveFromView(img ?: hit);
}

+ (void)twoFinger:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    CGPoint p = [g locationInView:g.view];
    UIView *hit = [g.view hitTest:p withEvent:nil] ?: g.view;
    UIView *img = hit;
    while (img && ![img isKindOfClass:[UIImageView class]]) img = img.superview;
    XHSForceSaveFromView(img ?: hit);
}

@end

#pragma mark - disableSave force

static BOOL XHS_retNO(id self, SEL _cmd) { (void)self; (void)_cmd; return NO; }
static BOOL XHS_retYES(id self, SEL _cmd) { (void)self; (void)_cmd; return YES; }
static void XHS_setDrop(id self, SEL _cmd, BOOL v) {
    (void)self; (void)_cmd;
    if (v) XHSLog(@"drop setDisable*:YES");
}
static id XHS_retYesNumber(id self, SEL _cmd) { (void)self; (void)_cmd; return @YES; }

static void XHSReplaceBoolGetter(Class cls, SEL sel, BOOL value) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    const char *t = method_getTypeEncoding(m);
    if (!t || (t[0] != 'B' && t[0] != 'c')) return;
    method_setImplementation(m, value ? (IMP)XHS_retYES : (IMP)XHS_retNO);
    XHSLog(@"patch %s -%s -> %d", class_getName(cls), sel_getName(sel), value);
}

static void XHSBlockBoolSetter(Class cls, SEL sel) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, (IMP)XHS_setDrop);
}

static void XHSPatchClass(Class cls) {
    if (!cls) return;
    XHSReplaceBoolGetter(cls, sel_registerName("disableSave"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("isDisableSave"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("forbidCopy"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("disableCopy"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("disableCopyAction"), NO);
    XHSReplaceBoolGetter(cls, sel_registerName("disableWatermark"), YES);
    XHSReplaceBoolGetter(cls, sel_registerName("disableWatermarkWhenSavingAlbum"), YES);

    XHSBlockBoolSetter(cls, sel_registerName("setDisableSave:"));
    XHSBlockBoolSetter(cls, sel_registerName("setForbidCopy:"));
    XHSBlockBoolSetter(cls, sel_registerName("setDisableCopy:"));

    Method share = class_getInstanceMethod(cls, sel_registerName("shareImageSaveEnable"));
    if (share) {
        const char *t = method_getTypeEncoding(share);
        if (t && t[0] == '@') method_setImplementation(share, (IMP)XHS_retYesNumber);
        else if (t && (t[0] == 'B' || t[0] == 'c')) method_setImplementation(share, (IMP)XHS_retYES);
    }

    const char *name = class_getName(cls);
    if (name && (strstr(name, "SaveProvider") || strstr(name, "ImageSave") ||
                 strstr(name, "SaveImage") || strstr(name, "NegativeFeedback"))) {
        Method en = class_getInstanceMethod(cls, sel_registerName("enable"));
        if (en) {
            const char *t = method_getTypeEncoding(en);
            if (t && (t[0] == 'B' || t[0] == 'c'))
                method_setImplementation(en, (IMP)XHS_retYES);
        }
    }
}

static void XHSScanClasses(void) {
    unsigned int n = 0;
    Class *list = objc_copyClassList(&n);
    if (!list) return;
    for (unsigned int i = 0; i < n; i++) {
        Class cls = list[i];
        const char *name = class_getName(cls);
        if (!name) continue;
        BOOL byName =
            strstr(name, "MediaSave") ||
            strstr(name, "ImageSave") ||
            strstr(name, "SaveConfig") ||
            strstr(name, "SaveProvider") ||
            strstr(name, "NoteImage") ||
            strstr(name, "XYPHNote") ||
            strstr(name, "NegativeFeedback") ||
            strstr(name, "NoteSave");
        BOOL bySel =
            class_getInstanceMethod(cls, sel_registerName("disableSave")) ||
            class_getInstanceMethod(cls, sel_registerName("setDisableSave:")) ||
            class_getInstanceMethod(cls, sel_registerName("shareImageSaveEnable"));
        if (byName || bySel) XHSPatchClass(cls);
    }
    free(list);
    // always try known class
    XHSPatchClass(objc_getClass("XYPHMediaSaveConfig"));
    XHSLog(@"class scan done (%u)", n);
}

#pragma mark - Constructor

__attribute__((constructor))
static void XHSImageSaveInit(void) {
    @autoreleasepool {
        NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
        // Allow injection into discover; also tolerate missing bid during early load
        if (bid.length && ![bid isEqualToString:@"com.xingin.discover"]) {
            // still allow if executable is discover (TrollFools injects into app)
            NSString *exe = [NSBundle mainBundle].executablePath.lastPathComponent ?: @"";
            if (![exe isEqualToString:@"discover"]) {
                return;
            }
        }
        XHSLog(@"loaded bid=%@ pid=%d", bid, getpid());
        XHSScanClasses();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSScanClasses();
            [XHSFloatUI install];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            XHSScanClasses();
        });
    }
}
