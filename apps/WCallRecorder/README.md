# WCallRecorder (Free) — WeChat 8.0.71

HiveNoAds 内的**免费、无授权**微信通话录音模块。  
根据商业版 `WCallRecorder.dylib` 的公开生命周期选择子做独立重写，**不含授权/联网校验**。

## 目标环境

- WeChat **8.0.71**
- iOS 14+ / 16.x
- Bootstrap / RootHide（`iphoneos-arm64e`）
- 也可经 TrollFools 等注入器注入 `WCallRecorder.dylib`

## v0.4.1 可见入口（解决“插件里看不到”）

1. **蓝色悬浮球**（默认开启）— 点开设置/录音列表  
2. 微信 **我 → 设置** 右上角 **「录音」** 按钮  
3. 若设备有 `WCPluginsMgr` 插件中心，会注册 **「WCallRecorder 通话录音」**  
4. 启动约 1 秒后 Toast：`WCallRecorder 已加载 v0.4.1`

## 功能

- 语音 / 视频通话、ilink、MultiTalk 生命周期检测
- 双轨 PCM 落盘：`mic.wav` + `remote.wav`
- 可选混音：`mixed.wav`（`WCR.WriteMixed`，默认开）
- 会话元数据：`meta.json`
- 通话中 `REC` 指示条 + 中文 Toast
- 设置页：开关 / 钩子诊断 / 强制测试会话 / 最近录音列表
- 纯 ObjC runtime hook，仅依赖 Foundation + UIKit

## 保存位置（微信沙盒）

```
Documents/WCallRecorder/<yyyyMMdd-HHmmss-hint>/
  mic.wav
  remote.wav
  mixed.wav   # 可选
  meta.json
```

## 开关（NSUserDefaults）

| Key | 默认 | 说明 |
|-----|------|------|
| `WCR.Enabled` | YES | 总开关 |
| `WCR.ShowFloating` | YES | 蓝色悬浮球 |
| `WCR.ShowIndicator` | YES | 顶部 REC 指示 |
| `WCR.PrivateMode` | NO | 隐私模式（隐藏 Toast） |
| `WCR.SampleRate` | 16000 | 采样率 8000–48000 |
| `WCR.WriteMixed` | YES | 结束后写 mixed.wav |
| `WCR.Verbose` | NO | 详细日志 |

## 构建（不改仓库其他代码）

Windows 无法本地编 arm64 iOS dylib，请用 GitHub Actions 或 macOS：

1. 把 `apps/WCallRecorder/` 推到你的 HiveNoAds fork（**仅新增该目录**）
2. 跑仓库已有 workflow：`apps/*/*.m` 会自动编出  
   `dist/WCallRecorder.dylib`
3. （可选，macOS/CI）单独打包 deb：

```bash
bash apps/WCallRecorder/package_deb.sh
# => dist/com.blueskycrb.wcallrecorder-rootless_0.4.1_iphoneos-arm64e.deb
```

## 安装

**越狱 RootHide / Bootstrap**

1. 安装 deb，或把 dylib + plist 放到  
   `/Library/MobileSubstrate/DynamicLibraries/`
2. 重启微信

**TrollFools / 注入**

1. 注入 `dist/WCallRecorder.dylib` 到微信  
2. 打开微信，应看到：  
   - Toast：`WCallRecorder 已加载 v0.4.1`  
   - 右侧蓝色悬浮球「录音插件」  
3. 日志：`[WCallRecorder] free rewrite for WeChat 8.0.71 loaded (v0.4.1, ...)`

> 注意：注入器列表里的条目 ≠ 微信内「插件中心」条目。  
> 本版在微信内自带悬浮球/设置按钮，不依赖商业版授权 UI。

## 验证

1. 注入后打开微信 → 看到悬浮球 / 加载 Toast  
2. 点悬浮球 → 设置页显示版本 `0.4.1` 与钩子数量  
3. 打一通微信语音/视频  
4. 应看到 `通话录音已开始` 与 `REC`  
5. 挂断后看 `Documents/WCallRecorder/` 下的 wav + meta.json  
6. 若提示「无音频」：PCM 钩子未命中，需要 Frida 补点

### Frida 补 PCM 钩子

```bash
# 先打一通电话后再 attach（VoIP 模块懒加载）
frida -U -n WeChat -l apps/WCallRecorder/find_voip_hooks.js
```

把找到的类/选择子填进 `WCallRecorder.m` 的 `WCRExtraAudioHooks()`：

```objc
hooks = @[
  @[@"SomeAudioClass", @"onMicData:length:", @"mic"],
  @[@"SomeAudioClass", @"onPlayData:length:", @"remote"],
];
```

## 说明与风险

- 仅供个人合法用途；录音请遵守当地法律与对方知情权
- 微信版本升级可能失效，需重新适配
- 商业版授权/网盘备份逻辑**未移植**（有意为之）
- 音频缓冲选择子为启发式；8.0.71 真机可能仍需 Frida 微调

## 版本

- **0.4.1**：可见 UI（悬浮球/设置入口/插件注册）、加载 Toast、诊断页、通话时激进音频扫描、remote 也可自动开会话
- **0.3.0**：mixed.wav、空音频提示、联系人 hint、通话开始二次扫 hook
- **0.2.0**：无授权双轨录音骨架 + 平等 hook 表