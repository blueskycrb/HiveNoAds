# NoAds / Tools dylibs (TrollFools)

按 **注入目标产品名**（拼音/英文）命名的动态库，专供 [TrollFools](https://github.com/Lessica/TrollFools) 注入。  
**不依赖** MobileSubstrate / 越狱。

## 下载

- [Releases](../../releases) 里每个产品名 dylib（如 `Fengchao.dylib`、`Xiaohongshu.dylib`）
- 或 [Actions](../../actions) 最新成功 run 的 artifact `noads-dylibs`

## 已支持

| dylib | 注入目标 | Bundle ID / 可执行名 | 功能 |
|-------|----------|----------------------|------|
| **Fengchao.dylib** | 丰巢 | `com.fcbox.hiveconsumer` / `HiveConsumer` | 去广告 |
| **Cainiao.dylib** | 菜鸟 | `com.cainiao.cnwireless` / `Cainiao4iPhone` | 去广告 |
| **LoLMobile.dylib** | 掌上英雄联盟 | `com.tencent.ied.app.lolbible` / `QTL` | 去广告 |
| **Zhiyuanhui.dylib** | 志愿汇 | `Volunteer`（分析版本 5.8.4） | 去广告 |
| **ChinaMobileCloud.dylib** | 中国移动云盘 | `com.chinamobile.mcloud` / `mCloud_iPhone`（13.0.0） | 去广告 |
| **ChinaRadio.dylib** | 中国广电 | `com.cbn.app` / `ChinaRadio`（2.0.8） | 去广告 |
| **Xiaohongshu.dylib** | 小红书 | `com.xingin.discover` / `discover`（9.38.1） | **图片+视频保存解锁** |


## 使用 (TrollFools)

1. 下载对应产品名 dylib（如 `Fengchao.dylib` 注入丰巢，`Xiaohongshu.dylib` 注入小红书）
2. TrollFools → 选对应 App → 注入
3. **彻底划掉** App 再打开

若之前注入过旧名（如 `HiveConsumer.dylib` / `discover.dylib` / `HiveNoAds.dylib`），请先在 TrollFools 里 **移除旧插件**，再注入新产品名（`Fengchao.dylib` / `Xiaohongshu.dylib` 等）。

## 启动变慢？(已优化)

旧版 `HiveNoAds` 启动偏慢的原因：

1. 每次启动 `objc_copyClassList` 扫全部类  
2. hook 了 **整个** `UIView` 的 `didMoveToWindow` / `setHidden`（每个控件都走）  
3. 默认 `NSLog` 很吵  
4. 2s / 3s / 6s 多次全量重扫  

**当前 `Fengchao.dylib`（v2）：**

- 只 hook 白名单里的广告类  
- 只给广告 View 子类装 `didMoveToWindow`  
- 默认无日志  
- 构造期一次 + 主线程一次 + **1.5s 后台再补一次**  

体感应接近未注入时的启动速度；若仍偏慢，把 iOS 版本发我再收紧白名单。

## 仓库结构（方便加新 App）

```
apps/
  Fengchao/
    Fengchao.m           → Fengchao.dylib（丰巢）
  Cainiao/
    Cainiao.m            → Cainiao.dylib（菜鸟）
  LoLMobile/
    LoLMobile.m          → LoLMobile.dylib（掌上英雄联盟）
  Zhiyuanhui/
    Zhiyuanhui.m         → Zhiyuanhui.dylib（志愿汇）
  ChinaMobileCloud/
    ChinaMobileCloud.m   → ChinaMobileCloud.dylib（中国移动云盘）
  ChinaRadio/
    ChinaRadio.m         → ChinaRadio.dylib（中国广电）
  Xiaohongshu/
    Xiaohongshu.m        → Xiaohongshu.dylib（小红书图片/视频保存）
  # 下一个 App:
  # SomeApp/
  #   SomeApp.m         → SomeApp.dylib
.github/workflows/build.yml   # 自动编译 apps/*/*.m
```

约定：

- 目录名 = dylib 名 = 注入目标产品名（拼音/英文，避免 GitHub 中文资源名问题；可执行名只作参考）  
- 每个 App 一个 `.m`，互不依赖  
- push 到 `main` 即构建全部 dylib 并发 Release  

需要去广告的新 App：丢解密包 / IPA 里主二进制，或说明 Bundle ID，我按同样结构加 `apps/新名字/`。

## 小红书 `Xiaohongshu.dylib`（解锁保存别人帖子图片 / 视频）

**优先原生保存**；若作者关闭下载权限仍拦，用右侧 **↓** 悬浮按钮或双指长按兜底保存。

1. 下载 [Releases](../../releases) 里的 **`Xiaohongshu.dylib`**
2. TrollFools → 选 **小红书** → 注入（若已注入旧版，先移除再注新版）
3. **彻底划掉**小红书再打开
4. **图片**：别人图文笔记 → 长按图片 / 分享 → **保存图片**
5. **视频**：别人视频笔记 → 分享 / 更多 → **保存视频**；原生失败时点 **↓** 兜底下载
6. 设置 → 小红书 → 照片 → **允许添加**

### v10 原理（图片 + 视频兜底）

作者关下载权限时，客户端常只是把 `disableSave` / `SaveProvider.enable` 等开关关掉，**原生按钮仍可能不可用**。v10 在 v9 基础上补视频：

1. **原生门控解锁（轻量）**
   - `XYPHMediaSaveConfig.disableSave = NO`、`shareImageSaveEnable / shareVideoSaveEnable = YES`
   - `SaveProvider.enable = YES`（仅保存相关类）
   - capa 下载权限 toast / i18n key 过滤
   - 相关 JSON 限流改写（<=512KB）
2. **兜底保存（关键）**
   - 屏幕右侧半透明 **↓** 悬浮按钮（可拖动）
   - 或 **双指长按** 媒体区域
   - **图片**：抓 CDN 原图 URL（`origin` / `url_size_large`）或当前 `UIImage`
   - **视频**：优先抓 `master_url` / `videoURL` / `sns-video` 等 CDN，`downloadTask` 落临时文件后 `creationRequestForAssetFromVideoAtFileURL` 写入相册
   - HLS（`.m3u8`）暂不支持；失败会 toast 提示

### v10 稳定性（继承 v8/v9）
- **启动期只 hook 已知类**：构造函数里不做 `objc_copyClassList` 全量扫描
- **去掉 `NSBundle localizedStringForKey:` 全局 hook**（v7 启动卡死主因）
- **去掉 `NSURLSession dataTask` 包装**（避免首页网络/打开笔记卡顿）
- **JSON 改写限流**：仅相关且 <=512KB 的 payload 才 rewrite
- **toast / i18n / mediaSaveConfig / authority**：加载时 known-only，约 1.8s 后后台一次延迟扫描
- **悬浮按钮约 2.4s 后挂载**，不在 ctor 里做 UI / 全类扫描

### 使用（重新注入后）
1. TrollFools 先 **移除旧 `Xiaohongshu.dylib` / `discover.dylib` / `小红书.dylib`**，再注入新构建
2. 冷启动应流畅；打开关闭下载权限的图文 / 视频笔记
3. 先试原生保存/分享里的“保存图片 / 保存视频”
4. 若仍提示作者关闭下载：点右侧 **↓**，或双指长按媒体
5. 视频会提示“正在下载视频…”，稍等后写入相册
6. 首次会弹相册权限，请允许
7. Console 可过滤 `[XHSMediaSave]`

### v9 / v8 / v7 说明
- v9：图片兜底可用（悬浮按钮 / 双指长按）
- v8：修好了卡死，但仅靠原生开关仍可能保存不了
- v7：在 ctor 扫全类 + hook NSBundle，易卡死/闪退

## 本地编译 (macOS)

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -dynamiclib -isysroot "$SDK" -arch arm64 -miphoneos-version-min=13.0 \
  -fobjc-arc -O2 -framework Foundation -framework UIKit \
  -o Fengchao.dylib apps/Fengchao/Fengchao.m

# Xiaohongshu 需要 Photos + AVFoundation + CoreGraphics:
# clang ... -framework Foundation -framework UIKit -framework Photos -framework CoreGraphics \
#   -o Xiaohongshu.dylib apps/Xiaohongshu/Xiaohongshu.m
```

## 调试

把 `apps/Fengchao/Fengchao.m` 顶部：

```objc
static const BOOL kVerbose = YES;
```

再推送构建。Console 过滤 `HiveConsumer` / `Fengchao`。

## 说明

- 仅供自有设备研究；可能违反 App 协议  
- 未改支付 / 开柜 / 服务端校验  
- 大版本升级后若广告回来，需按新二进制补白名单  
