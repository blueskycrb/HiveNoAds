# NoAds dylibs (TrollFools)

按 **App 可执行文件名 / 产品名** 命名的去广告动态库，专供 [TrollFools](https://github.com/Lessica/TrollFools) 注入。  
**不依赖** MobileSubstrate / 越狱。

## 下载

- [Releases](../../releases) 里每个 `AppName.dylib`
- 或 [Actions](../../actions) 最新成功 run 的 artifact `noads-dylibs`

## 已支持

| dylib | App | Bundle ID / 可执行名 |
|-------|-----|----------------------|
| **HiveConsumer.dylib** | 丰巢 | `com.fcbox.hiveconsumer` |
| **Cainiao4iPhone.dylib** | 菜鸟 | `com.cainiao.cnwireless` |
| **QTL.dylib** | 掌上英雄联盟 | `com.tencent.ied.app.lolbible` |
| **Volunteer.dylib** | 志愿汇 | 可执行名 `Volunteer`（分析版本 5.8.4） |

## 使用 (TrollFools)

1. 下载与 App 同名的 dylib（如 `HiveConsumer.dylib`）
2. TrollFools → 选对应 App → 注入
3. **彻底划掉** App 再打开

若之前注入过旧的 `HiveNoAds.dylib`，请先在 TrollFools 里 **移除旧插件**，再注入新的 `HiveConsumer.dylib`。

## 启动变慢？(已优化)

旧版 `HiveNoAds` 启动偏慢的原因：

1. 每次启动 `objc_copyClassList` 扫全部类  
2. hook 了 **整个** `UIView` 的 `didMoveToWindow` / `setHidden`（每个控件都走）  
3. 默认 `NSLog` 很吵  
4. 2s / 3s / 6s 多次全量重扫  

**当前 `HiveConsumer.dylib`（v2）：**

- 只 hook 白名单里的广告类  
- 只给广告 View 子类装 `didMoveToWindow`  
- 默认无日志  
- 构造期一次 + 主线程一次 + **1.5s 后台再补一次**  

体感应接近未注入时的启动速度；若仍偏慢，把 iOS 版本发我再收紧白名单。

## 仓库结构（方便加新 App）

```
apps/
  HiveConsumer/
    HiveConsumer.m      → 编译为 HiveConsumer.dylib
  Cainiao4iPhone/
    Cainiao4iPhone.m    → 编译为 Cainiao4iPhone.dylib
  QTL/
    QTL.m               → 编译为 QTL.dylib（掌上英雄联盟）
  Volunteer/
    Volunteer.m         → 编译为 Volunteer.dylib
  # 下一个 App:
  # SomeApp/
  #   SomeApp.m         → SomeApp.dylib
.github/workflows/build.yml   # 自动编译 apps/*/*.m
```

约定：

- 目录名 = dylib 名 = 建议与 App 可执行文件名一致  
- 每个 App 一个 `.m`，互不依赖  
- push 到 `main` 即构建全部 dylib 并发 Release  

需要去广告的新 App：丢解密包 / IPA 里主二进制，或说明 Bundle ID，我按同样结构加 `apps/新名字/`。

## 本地编译 (macOS)

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
clang -dynamiclib -isysroot "$SDK" -arch arm64 -miphoneos-version-min=13.0 \
  -fobjc-arc -O2 -framework Foundation -framework UIKit \
  -o HiveConsumer.dylib apps/HiveConsumer/HiveConsumer.m
```

## 调试

把 `apps/HiveConsumer/HiveConsumer.m` 顶部：

```objc
static const BOOL kVerbose = YES;
```

再推送构建。Console 过滤 `HiveConsumer`。

## 说明

- 仅供自有设备研究；可能违反 App 协议  
- 未改支付 / 开柜 / 服务端校验  
- 大版本升级后若广告回来，需按新二进制补白名单  
