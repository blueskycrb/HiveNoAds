# AllowNotifications.dylib

自动允许目标 App 的通知权限弹窗。

## 构建

源码：`apps/AllowNotifications/AllowNotifications.m`

由 `.github/workflows/build.yml` 与其它 apps 一起编译为：

```text
dist/AllowNotifications.dylib
```

## 使用（TrollFools）

1. 下载 `AllowNotifications.dylib`
2. TrollFools 选择目标 App 注入
3. 彻底杀掉 App 再打开
4. 通知权限弹窗应自动按“允许”

## 原理

1. Hook `requestAuthorizationWithOptions:completionHandler:` 直接回调 YES
2. Hook `UNNotificationSettings` 读成已授权
3. 兜底自动点通知权限 Alert 的“允许”
