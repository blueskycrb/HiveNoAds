# Allow Notifications（Bootstrap / RootHide 越狱插件）

自动允许 App 首次打开时的通知权限弹窗：

- `xxx 想给你发送通知`
- `Would Like to Send You Notifications`

功能对标自动允许网络权限类插件，但本包为独立实现，包名使用本仓库作者命名空间。

## Bootstrap / RootHide 格式（重要）

Bootstrap 使用 **RootHide** 包格式，不是 Dopamine 的 `/var/jb` rootless 格式。

| 字段 | 正确值 |
|------|--------|
| Architecture | **`iphoneos-arm64e`**（不是 `iphoneos-arm64`） |
| 安装布局 | **无 `/var/jb` 前缀** 的 rootful 路径 |
| 安装路径 | `/Library/MobileSubstrate/DynamicLibraries/AllowNotifications.{dylib,plist}` |

## 包信息

| 字段 | 值 |
|------|----|
| Package | `com.blueskycrb.allownotifications-rootless` |
| Architecture | `iphoneos-arm64e` |
| Scheme | Bootstrap / RootHide |
| Depends | `mobilesubstrate (>= 0.9.5000)`, `firmware (>= 14.0)` |

Filter：`com.apple.UIKit` + `com.apple.springboard`

## 构建产物

```text
dist/com.blueskycrb.allownotifications-rootless_<ver>_iphoneos-arm64e.deb
```

## 安装

1. Sileo / Filza 安装 `.deb`
2. 注销 / respring
3. 打开会申请通知权限的 App 验证

## 原理

1. Hook `requestAuthorizationWithOptions:completionHandler:` 直接回调 YES
2. Hook `UNNotificationSettings` 报告已授权
3. 兜底自动点通知权限 Alert 的“允许”

## 源码

- 逻辑：`AllowNotifications.m`
- 控制文件：`control`
- 过滤器：`AllowNotifications.plist`
- 打包脚本：`package_deb.sh`