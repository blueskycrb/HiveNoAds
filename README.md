# HiveNoAds

丰巢 iOS App（`com.fcbox.hiveconsumer` / `HiveConsumer`）**去广告 dylib**，面向 **TrollFools** 注入，**不依赖** MobileSubstrate / ElleKit / 越狱 Substrate。

基于 **HiveConsumer 6.32.0** 解密二进制静态分析编写。

## 下载

1. 打开本仓库 [Actions](../../actions) → 最新成功的 **Build HiveNoAds dylib**
2. 下载 Artifact **`HiveNoAds-dylib`**，解压得到 `HiveNoAds.dylib`  
   或在 [Releases](../../releases) 直接下载

## TrollFools 使用

1. 手机安装 [TrollFools](https://github.com/Lessica/TrollFools)（需 TrollStore）
2. 将 `HiveNoAds.dylib` 拷到手机（文件 App / 电脑 iTunes 等）
3. 打开 TrollFools → 选择 **丰巢** → 注入该 dylib
4. **彻底关掉** 丰巢后重新打开（冷启动）

成功时系统日志可见：`[HiveNoAds] loaded in com.fcbox.hiveconsumer`

## 广告栈（分析摘要）

| 层级 | 组件 |
|------|------|
| 业务 | `SplashAdManager` / `FCSplashADSManager` / `AdCenter` / `OpenScrAdLib*` / `InterstScrAdLib*` / `NativeSplashAdView` 等 |
| 聚合 | **WindMill（Sigmob）**、ToBid、AnyThink、UBiX |
| 渠道 | 穿山甲 CSJ、广点通 GDT、快手 KSAd、百度等 |
| 其它 | DCloud Uni：`DCUniSplashAd` 等 |

## 原理

纯 `objc/runtime`：

1. 阻断 WindMill / DCUni 的 `loadAd*` / `showAd*` / `isReady`
2. 禁止 `+[WindMillAds setupSDKWithAppId:sdkConfigures:]`
3. 扫描类名像广告的类，替换广告控制方法
4. 隐藏广告 UIView，拦截广告 VC 的 `present`

激励视频默认只禁止展示。若要实验“假装发奖”，改 `HiveNoAds.m`：

```objc
static const BOOL kHiveNoAdsFakeReward = YES;
```

后重新跑 Actions 编译。

## 本地编译（可选，macOS）

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -dynamiclib -isysroot "$SDK" -arch arm64 -miphoneos-version-min=13.0 \
  -fobjc-arc -O2 -framework Foundation -framework UIKit \
  -o HiveNoAds.dylib HiveNoAds.m
```

## 仓库文件

- `HiveNoAds.m` — dylib 源码（TrollFools 用这个）
- `.github/workflows/build.yml` — GitHub Actions 自动编 arm64 dylib
- `Tweak.x` / `Makefile` — 传统 Theos 越狱插件备选（非 TrollFools 必需）

## 注意

- 仅供自有设备学习研究；可能违反 App 用户协议  
- 未修改支付 / 开柜 / 服务端会员校验  
- 大版本更新后类名可能变化，需按新二进制补 hook  
- 若闪退：用 TrollFools 移除注入，或提 Issue 附 iOS 版本与 App 版本  

## License

MIT（自用 / 研究）
