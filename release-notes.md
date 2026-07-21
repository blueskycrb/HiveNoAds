## Douyin.dylib v1.7

- **严格当前条**：全窗口只锁一个居中 feed cell + 与之重叠的播放器（不再合并多 VC / 多列表）
- **无水印优先**：try 顺序 no-wm → 高清 → 带水印 download 垫底
- 低码率自动换源仅针对 play 流，避免误跳到下一条大文件
- 保留 v1.6 画质打分与高画质转码预设

## Douyin.dylib v1.6

- **画质优先**：`downloadAddr` / origin / 高分辨率 / 高 `br=` 码率优先于播放器自适应流
- 下载后若体积/码率过低自动换下一条候选（避免糊糊的 play 流当成功）
- 相册转码预设：Passthrough → Highest → 1080p（不再先 Medium）
- 仍只采当前 feed 条 + 安全启动

## Douyin.dylib v1.5

- **当前条优先**：只从最居中的 feed cell + 正在播放的 player 取 URL，避免保存成下一条预加载视频
- 仍安全启动：默认不 hook JSON / NSUserDefaults / toast / i18n
- 保留 Photos 直写优先、无水印 URL 变体
- 使用：TrollFools 移除旧插件 → 注入新 Douyin.dylib → 彻底杀进程冷启动

## Douyin.dylib v1.4

- **安全启动**：默认不再 hook JSON / NSUserDefaults / toast / i18n（解决一打开就闪退）
- 仅悬浮保存 + 下载写相册；5 秒后后台轻量 patch 抖音 preventDownload 等 BOOL 门
- 保留 v1.3：Photos 直写优先、无水印 URL 变体、后台缓存扫描
- 使用：TrollFools 移除旧插件 → 注入新 Douyin.dylib → 彻底杀进程冷启动

## Douyin.dylib v1.3

- **防闪退**：关闭危险全量 class 扫描后的收尾；收窄 NSUserDefaults 匹配；KVC 仅扫 Player/Video/Aweme 等视图
- **保存后不再先转码**：Photos 直写优先，失败再 AV 转码（降低 OOM / watchdog）
- **去水印优先**：`downloadAddr` 高分；`playwm` 重罚；候选 URL 自动生成 `play` / `watermark=0` 变体并重排
- **缓存扫描**：移到后台线程，只扫 tmp/Caches、限深度与候选数
- 使用：TrollFools 移除旧 `Douyin.dylib` 后注入新包 → 彻底杀进程冷启动 → 点悬浮 ↓ 保存

## Douyin.dylib v1.2

- 真正按**视频**保存：多地址重试，下载内容必须是可播放视频才会写相册
- 不再把封面/图床 URL 误判成视频后提示“已保存”
- 写入相册后校验 `localIdentifier` + `mediaType == Video`
- 从可见 cell / 顶层 VC / 播放器缓存更积极收集 `downloadAddr` / `playAddr`
- 仅封面可取时明确提示“未找到视频，改为保存封面图”

使用：TrollFools 注入 `Douyin.dylib` 到抖音 → 点悬浮 ↓ 或双指长按 → 允许相册权限 → 到系统相册「视频」里查看。


按**注入目标（App 产品名）** 命名的 dylib（TrollFools，无 Substrate）。

> GitHub Release 资源名使用**产品名拼音/英文**（中文文件名会被 GitHub 改成 default.dylib）。

| 文件 | 注入目标 | 功能 |
|------|----------|------|
| `Fengchao.dylib` | 丰巢 (`com.fcbox.hiveconsumer` / `HiveConsumer`) | 去广告 |
| `Cainiao.dylib` | 菜鸟 (`com.cainiao.cnwireless` / `Cainiao4iPhone`) | 去广告 |
| `LoLMobile.dylib` | 掌上英雄联盟 (`com.tencent.ied.app.lolbible` / `QTL`) | 去广告 |
| `Zhiyuanhui.dylib` | 志愿汇 (`Volunteer` 5.8.4) | 去广告 |
| `ChinaMobileCloud.dylib` | 中国移动云盘 (`com.chinamobile.mcloud` / `mCloud_iPhone`) | 去广告 |
| `ChinaRadio.dylib` | 中国广播 (`com.cbn.app` / `ChinaRadio`) | 去广告 |
| **`Xiaohongshu.dylib`** | **小红书** (`com.xingin.discover` / `discover`) | **解锁保存别人帖子图片/视频** |
| **`Douyin.dylib`** | **抖音** (`com.ss.iphone.ugc.Aweme` / `Aweme` 38.7.0) | **解锁保存视频/图片** |

> 旧名请先移除再注入：`HiveConsumer.dylib` → `Fengchao.dylib`；`discover.dylib` → `Xiaohongshu.dylib` 等。

## 用法
1. 下载对应产品名 `*.dylib`（见上表）
2. TrollFools → 选择对应 App → 注入
3. 彻底杀掉 App 后冷启动

## 小红书 `Xiaohongshu.dylib`（v10.2：图片 + 视频悬浮兜底）
- 保持 v8/v9 轻量启动：无 NSBundle 全局 hook、无 ctor 全类扫描、无 session 包装
- 原生门控：`disableSave=NO` / `SaveProvider.enable` / capa toast 过滤 / JSON 限流改写
- **图片兜底**：右侧半透明 ↓ + 双指长按，抓 CDN 原图 URL 或当前 UIImage 写相册
- **视频兜底**：抓 `master_url` / `videoURL` / `sns-video` 等 CDN；下载后用 AVFoundation 重编码再写相册，避免 PHPhotosErrorDomain 3302
- 使用：TrollFools 移除旧 dylib 后重注；冷启动 → 打开锁下载笔记 → 点 ↓ 或双指长按
- 设置 → 小红书 → 照片 → 允许添加
- 不破坏付费墙；服务端硬拦时原生入口仍可能不出现，用悬浮按钮

## 抖音 `Douyin.dylib`（v1：视频/图片保存）
- 轻量启动：known-class 门控 + 限流 JSON 改写；延迟一次后台类扫描
- 门控：`preventDownload=NO` / `allowDownload=YES` / `canDownload=YES`（`AWEAwemeModel` 等）
- JSON：`prevent_download` / `allow_download` / `can_download`
- **兜底**：青色悬浮 ↓ + 双指长按；抓 `downloadAddr` / `playAddr` / `urlList`；优先无水印 download；跳过 m3u8
- 下载后 AVFoundation 重导出再写相册（规避 PHPhotos 3302）
- 使用：注入 `Douyin.dylib` → 冷启动抖音 → 打开作品 → 点 ↓ / 双指长按
- 设置 → 抖音 → 照片 → 允许添加

## v2 性能（去广告类）
- 取消全进程类扫描（各 App 按自身实现）
- 取消 UIView 全局 swizzle
- 默认关闭日志
