# WeApp Helper（Bootstrap / RootHide 越狱插件）

针对旧版 **微信小程序助手**（`com.25mao.weapptool`）在 **iOS 16.5.1 + 微信 8.0.71** 闪退的问题重写。

## 旧插件为什么闪退

1. 全局 hook `MMServiceCenter defaultCenter`（微信 8.0.x 服务体系已变）
2. 启动即 hook `NewMainFrameViewController viewDidLoad`
3. 依赖过时私有 UI / WCPlugins 接口
4. Debug MonkeyDev 构建 + Dopamine `/var/jb` 包格式（不适合 Bootstrap）

## 本插件策略

- **不 hook** `MMServiceCenter` / `NewMainFrameViewController`
- 每个 hook 前检查 class / selector 是否存在
- 设置页用 **原生 UIKit**（不依赖 `WCTableViewManager`）
- 服务查找优先 `MMContext`，失败再回退 `MMServiceCenter`
- 私有 API 调用包在 `@try/@catch` 中

## 功能

| 功能 | 说明 |
|------|------|
| 强制调试 / vConsole | hook `WAWebViewController isOpenDebugAndVConsole` |
| 设置入口 | 微信「我 → 设置」导航栏右侧「小程序」按钮 |
| 打开小程序 | 设置页输入 userName / path |
| jumpWxa 改写 | 可选：自定义 AppId 改写跳转链接 |

## Bootstrap / RootHide 格式

| 字段 | 值 |
|------|----|
| Package | `com.blueskycrb.weapptool-rootless` |
| Architecture | `iphoneos-arm64e` |
| 路径 | `/Library/MobileSubstrate/DynamicLibraries/WeAppHelper.{dylib,plist}` |
| Filter | `com.tencent.xin` |
| Conflicts | `com.25mao.weapptool.rootless` 等旧包 |

## 安装

1. **先卸载** 旧的「微信小程序助手 / WeAppTool」并 respring  
2. Sileo / Filza 安装  
   `com.blueskycrb.weapptool-rootless_<ver>_iphoneos-arm64e.deb`  
3. respring  
4. 打开微信 → 我 → 设置 → 右上角「小程序」

## 构建产物

```text
dist/com.blueskycrb.weapptool-rootless_<ver>_iphoneos-arm64e.deb
```

## 源码

- `WeAppHelper.m`
- `control` / `WeAppHelper.plist` / `package_deb.sh`
