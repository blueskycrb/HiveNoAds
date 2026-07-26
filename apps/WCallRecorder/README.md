# WCallRecorder (Free) — WeChat 8.0.71

HiveNoAds 内的**免费、无授权**微信通话录音模块。  
根据商业版 `WCallRecorder.dylib` 的公开生命周期选择子做独立重写，**不含授权/联网校验**。

## 目标环境

- WeChat **8.0.71**
- iOS 14+ / 16.x
- Bootstrap / RootHide（`iphoneos-arm64e`）
- 也可经 TrollFools 等注入器注入 `WCallRecorder.dylib`

## v0.5.0 新特性

1. **MP3 输出**：通话结束混音后编码为 `call.mp3`，并复制到根目录 `{备注}_{时间}.mp3`
2. **备注命名**：优先联系人备注（`m_nsRemark`），可读中文文件名
3. **列表可播放**：点最近录音 → 播放 / 分享 / 复制路径 / 删除
4. **挂断自动结束**：更多 stop/hangup 钩子 + 无 PCM 静默看门狗（约 10s）
5. 仍保留双轨 `mic.wav` / `remote.wav`，可选 `mixed.wav`

## 可见入口

1. **蓝色悬浮球**（默认开启）
2. 微信 **我 → 设置** 右上角 **「录音」** 按钮
3. 若有 `WCPluginsMgr` 插件中心：注册 **「WCallRecorder 通话录音」**
4. 启动 Toast：`WCallRecorder 已加载 v0.5.0`

## 保存位置（微信沙盒）

```
Documents/WCallRecorder/
  {备注}_{yyyyMMdd_HHmmss}/
    mic.wav
    remote.wav
    mixed.wav   # 可选
    call.mp3
    meta.json
  {备注}_{yyyyMMdd_HHmmss}.mp3   # 根目录快捷副本
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
| `WCR.Verbose` | NO | 详细日志 / 激进 PCM 扫描 |

## 构建

Windows 无法本地编 arm64 iOS dylib，请用 GitHub Actions：

1. 推送 `apps/WCallRecorder/`（含 `third_party/shine`）
2. workflow 会额外链接 AVFoundation + Shine 源码
3. 产物：`dist/WCallRecorder.dylib`

```bash
bash apps/WCallRecorder/package_deb.sh
# => dist/com.blueskycrb.wcallrecorder-rootless_0.5.0_iphoneos-arm64e.deb
```

## 安装

1. **先删除旧版** `WCallRecorder.dylib` / 旧 deb
2. 注入新 dylib 或安装新 deb
3. **冷启动微信**（划掉后台再开）
4. 应看到 Toast `v0.5.0` 与悬浮球

## 验证清单

1. 插件列表只出现 **1 条** WCallRecorder
2. 接听微信电话不闪退
3. 通话中有 REC / Toast「通话录音已开始」
4. **挂断后自动结束**，Toast「通话录音已保存(MP3)」
5. 最近录音可点开 **播放**
6. 文件名含来电备注中文，扩展名 `.mp3`

若提示「无音频」：PCM 钩子未命中。点「重新扫描钩子」，或用 Frida 补 `WCRExtraAudioHooks()`。

```bash
frida -U -n WeChat -l apps/WCallRecorder/find_voip_hooks.js
```

## 说明与风险

- 仅供个人合法用途；录音请遵守当地法律与对方知情权
- 本模块为免费重写，不破解商业版授权逻辑
