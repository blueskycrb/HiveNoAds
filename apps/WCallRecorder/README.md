## v0.5.6

- Learn commercial plugin model: ObjC lifecycle + runtime sink discovery (no auth crack)
- dyld add-image observer + delayed rescan when VoIP modules load
- AVAudioSession setCategory/setActive start/stop assist
- Safer lifecycle trampoline arity matching (reduce answer crash)
- Remark/UI scrape naming + MP3 export + hangup auto-stop

# WCallRecorder (Free) - WeChat 8.0.71

HiveNoAds 内的**免费、无授权**微信通话录音模块。
根据商业版 `WCallRecorder.dylib` 的公开生命周期选择子做独立重写，**不含授权/联网校验**。

## v0.5.5 修复（学习商业版采集模型）

商业版逆向结论：
1. **只走 ObjC 钩子**（`MSHookMessageEx`），不依赖 AudioUnit C API
2. PCM 选择子被混淆，运行时动态解析
3. 现代微信/iOS15+ 大量使用 **dyld chained fixups**，旧 fishhook 会得到 AU=0

本版对应改进：
1. **ObjC PCM 探针**：通话中扫描音频相关类，按签名+名称安装探针，命中后持久化
2. **通话中持续重扫**：idle watchdog 每 2 秒重装/补钩
3. **chained-fixup 重绑定**：AudioUnit 符号同时支持 classic + chained
4. **候选方法落盘**：`Documents/WCallRecorder/candidates.txt`（无需 Frida 也能看候选）
5. float32 / sample-count 启发式转换 PCM16
6. 备注命名 MP3 + 挂断自动结束（保留）

## 目标环境

- WeChat **8.0.71**
- iOS 14+ / 16.x
- Bootstrap / RootHide（`iphoneos-arm64e`）
- 也可经 TrollFools 等注入 `WCallRecorder.dylib`

## 功能

1. **MP3 输出**：`call.mp3` + 根目录 `{备注}_{时间}.mp3`
2. **备注命名**：优先联系人备注
3. **列表可播放**：最近录音播放/分享/复制路径/删除
4. **挂断自动结束**
5. 保留 `mic.wav` / `remote.wav` / 可选 `mixed.wav`

## 安装 / 复测

1. **先删除旧版** WCallRecorder.dylib / 旧 deb
2. 注入新 dylib 或安装新 deb
3. **冷启动微信**（划掉后再开）
4. Toast 应显示 `WCallRecorder 已加载 v0.5.5`
5. 打一通语音电话，说几句话后挂断
6. 状态页确认：
   - 版本 0.5.5
   - 通话中 `probe` 有 hits 或 mic/remote > 0
   - 若仍为 0，打开微信容器内 `Documents/WCallRecorder/candidates.txt` 发我

## 构建

Windows 无法本地编 arm64 iOS dylib，请用 GitHub Actions 推送 `apps/WCallRecorder/`。

```bash
bash apps/WCallRecorder/package_deb.sh
# => dist/com.blueskycrb.wcallrecorder-rootless_0.5.5_iphoneos-arm64e.deb
```