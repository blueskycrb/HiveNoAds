# NoAds / Tools dylibs (TrollFools)

按**注入目标产品名**（拼音/英文）命名的动态库，专供 [TrollFools](https://github.com/Lessica/TrollFools) 注入。  
**不依赖** MobileSubstrate / 越狱。

## 下载

- [Releases](../../releases) 里每个产品名 dylib（如 `Fengchao.dylib`、`Xiaohongshu.dylib`、`Douyin.dylib`）
- 或 [Actions](../../actions) 最新成功 run 的 artifact `noads-dylibs`

## 已支持

| dylib | 注入目标 | Bundle ID / 可执行名 | 功能 |
|-------|----------|----------------------|------|
| **Fengchao.dylib** | 丰巢 | `com.fcbox.hiveconsumer` / `HiveConsumer` | 去广告 |
| **Cainiao.dylib** | 菜鸟 | `com.cainiao.cnwireless` / `Cainiao4iPhone` | 去广告 |
| **LoLMobile.dylib** | 掌上英雄联盟 | `com.tencent.ied.app.lolbible` / `QTL` | 去广告 |
| **Zhiyuanhui.dylib** | 志愿汇 | `Volunteer`（分析版本 5.8.4） | 去广告 |
| **ChinaMobileCloud.dylib** | 中国移动云盘 | `com.chinamobile.mcloud` / `mCloud_iPhone`（3.0.0） | 去广告 |
| **ChinaRadio.dylib** | 中国广播 | `com.cbn.app` / `ChinaRadio`（1.0.8） | 去广告 |
| **Xiaohongshu.dylib** | 小红书 | `com.xingin.discover` / `discover`（9.38.1） | **图片+视频保存解锁** |
| **Douyin.dylib** | 抖音 | `com.ss.iphone.ugc.Aweme` / `Aweme`（38.7.0） | **视频/图片保存解锁** |


## 使用 (TrollFools)

1. 下载对应产品名 dylib（如 `Fengchao.dylib` 注入丰巢，`Xiaohongshu.dylib` 注入小红书，`Douyin.dylib` 注入抖音）
2. TrollFools → 选对应 App → 注入
3. **彻底划掉** App 再打开

若之前注入过旧名（如 `HiveConsumer.dylib` / `discover.dylib` / `HiveNoAds.dylib`），请先在 TrollFools 里**移除旧插件**，再注入新产品名（`Fengchao.dylib` / `Xiaohongshu.dylib` / `Douyin.dylib` 等）。

## 启动变慢？（已优化）

旧版 `HiveNoAds` 启动偏慢的原因：

1. 每次启动 `objc_copyClassList` 扫全部类  
2. hook 了**整个** `UIView` 的 `didMoveToWindow` / `setHidden`（每个控件都跑）  
3. 默认 `NSLog` 很吵  
4. 2s / 3s / 6s 多次全量重扫  

**当前 `Fengchao.dylib`（v2）：**

- 只 hook 白名单里的广告类  
- 只给广告 View 子类装 `didMoveToWindow`  
- 默认无日志  
- 构造期一次 + 主线程一次 + **1.5s 后台再补一次**  

体验应接近未注入时的启动速度；若仍偏慢，把 iOS 版本发我再收紧白名单。

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
    ChinaRadio.m         → ChinaRadio.dylib（中国广播）
  Xiaohongshu/
    Xiaohongshu.m        → Xiaohongshu.dylib（小红书图片/视频保存）
  Douyin/
    Douyin.m             → Douyin.dylib（抖音视频/图片保存）
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

**优先原生保存**；若作者关闭下载权限仍卡，用右侧 **↓** 悬浮按钮或双指长按兜底保存。

1. 下载 [Releases](../../releases) 里的 **`Xiaohongshu.dylib`**
2. TrollFools → 选**小红书** → 注入（若已注入旧版，先移除再注新版）
3. **彻底划掉**小红书再打开
4. **图片**：别人图文笔记 → 长按图片 / 分享 → **保存图片**
5. **视频**：别人视频笔记 → 分享 / 更多 → **保存视频**；原生失败时点 **↓** 兜底下载
6. 设置 → 小红书 → 照片 → **允许添加**

### v10 原理（图片 + 视频兜底）

作者关下载权限时，客户端常只是把 `disableSave` 等开关打成不可用；CDN 原图/视频 URL 有时仍可拉取。  
本库会：

- 解锁原生保存相关开关 / toast  
- 提供悬浮 **↓** 与双指长按，从当前页模型 / 视图树抓 CDN URL 或 `UIImage`  
- 视频经 AVFoundation 重导出再写入相册，规避 PHPhotosErrorDomain 3302  

不破坏付费墙；服务端硬拦时原生入口仍可能不出现，用悬浮按钮。

## 抖音 `Douyin.dylib`（解锁保存视频 / 图片）

**v1.4**：安全启动（无全局 hook）+ 在真视频保存基础上加强**防闪退**与**去水印优先**（`downloadAddr` / `playwm→play` / Photos 直写优先）。若只找到封面会明确提示，不会假装“视频已保存”。


**优先尝试解锁原生下载门控**；仍不可用时用右侧青色 **↓** 悬浮按钮或双指长按兜底。

1. 下载 [Releases](../../releases) 里的 **`Douyin.dylib`** (v1.3)（ASCII 名，避免 GitHub 把中文资源改成 `default.dylib`）
2. TrollFools → 选**抖音** → 注入（先移除旧插件）
3. **彻底划掉**抖音再冷启动
4. 打开视频作品 → 点右侧 **↓**，或双指长按画面
5. 首次使用请允许**添加照片**权限（设置 → 抖音 → 照片 → 允许添加）

### v1 原理

- Hook `preventDownload` / `allowDownload` / `canDownload` 等模型门控  
- JSON 改写 `prevent_download` / `allow_download` / `can_download`  
- 兜底从 `AWEAwemeModel` / `downloadAddr` / `playAddr` / `urlList` 等抓 CDN  
- 优先无水印 download 地址；跳过 m3u8；下载后 AV 重导出再写相册  

> 部分作品服务端仅下发加密/HLS 流时，兜底可能提示暂不支持 m3u8。


