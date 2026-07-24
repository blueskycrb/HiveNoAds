# Allow Notifications（Bootstrap / RootHide 越狱插件）

自动允许 App 首次打开时的通知权限弹窗：

- `xxx 想给你发送通知`
- `Would Like to Send You Notifications`

对应 **GHAllowNetwork（自动允许网络）** 的通知版。

## 包信息

| 字段 | 值 |
|------|----|
| Package | `byg.iosios.net.ghallownotifications-rootless` |
| Architecture | `iphoneos-arm64` |
| Scheme | Bootstrap / RootHide（`/var/jb`） |
| Depends | `mobilesubstrate (>= 0.9.5000)`, `firmware (>= 14.0)` |

安装路径：

```text
/var/jb/Library/MobileSubstrate/DynamicLibraries/AllowNotifications.dylib
/var/jb/Library/MobileSubstrate/DynamicLibraries/AllowNotifications.plist
```

Filter：`com.apple.UIKit` + `com.apple.springboard`（全局注入）

## 构建产物

GitHub Actions 会产出：

```text
dist/byg.iosios.net.ghallownotifications-rootless_1.0.0_iphoneos-arm64.deb
```

（中间产物 `AllowNotifications.dylib` 仅用于打进 deb，不是最终交付。）

## 安装

1. 用 Sileo / Filza 安装 `.deb`
2. 注销 / respring
3. 打开任意会申请通知权限的 App，弹窗应自动按“允许”

## 原理

1. Hook `-[UNUserNotificationCenter requestAuthorizationWithOptions:completionHandler:]` 直接回调 `YES`，跳过系统授权表
2. Hook `UNNotificationSettings` 相关 getter，对 App 报告已授权
3. 兜底：匹配通知权限文案的 `UIAlertController` / `SBUserNotificationAlert` 自动点允许

## 源码

- 逻辑：`AllowNotifications.m`
- 控制文件：`control`
- 过滤器：`AllowNotifications.plist`
- 打包脚本：`package_deb.sh`