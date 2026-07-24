# Mini Program Helper (Bootstrap / RootHide + TrollFools)

Display name: **Mini Program Helper**  
Technical name: `WeAppHelper` (ASCII artifact names for GitHub releases)

Crash-safe rewrite of the old WeChat mini-program helper for **iOS 16.5.1 + WeChat 8.0.71**.

## Artifacts

| Type | File | Use |
|------|------|-----|
| Jailbreak deb | `com.blueskycrb.weapptool-rootless_<ver>_iphoneos-arm64e.deb` | Bootstrap/RootHide; Sileo shows **Mini Program Helper** |
| dylib | `WeAppHelper.dylib` | Inject into WeChat with TrollFools |

Use either the deb or the dylib, not both.

## Install

### Jailbreak deb
1. Uninstall old WeAppTool / 25mao packages
2. Install the deb → respring
3. WeChat → Me → Settings → top-right **Helper**

### TrollFools dylib
1. Inject `WeAppHelper.dylib` into WeChat
2. Force-quit WeChat and reopen
3. WeChat → Me → Settings → top-right **Helper**

## Features
- Force debug / vConsole
- Open a mini program from Settings
- Optional jumpWxa AppId rewrite

## Package
- Package: `com.blueskycrb.weapptool-rootless`
- Name: **Mini Program Helper**
- Architecture: `iphoneos-arm64e`
