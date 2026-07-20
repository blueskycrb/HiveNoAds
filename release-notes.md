按 **注入目标（App 产品名）** 命名的 dylib（TrollFools，无 Substrate）。

> GitHub Release 资源名使用 **产品名拼音/英文**（中文文件名会被 GitHub 改成 default.dylib）。

| 文件 | 注入目标 | 功能 |
|------|----------|------|
| `Fengchao.dylib` | 丰巢 (`com.fcbox.hiveconsumer` / `HiveConsumer`) | 去广告 |
| `Cainiao.dylib` | 菜鸟 (`com.cainiao.cnwireless` / `Cainiao4iPhone`) | 去广告 |
| `LoLMobile.dylib` | 掌上英雄联盟 (`com.tencent.ied.app.lolbible` / `QTL`) | 去广告 |
| `Zhiyuanhui.dylib` | 志愿汇 (`Volunteer` 5.8.4) | 去广告 |
| `ChinaMobileCloud.dylib` | 中国移动云盘 (`com.chinamobile.mcloud` / `mCloud_iPhone`) | 去广告 |
| `ChinaRadio.dylib` | 中国广电 (`com.cbn.app` / `ChinaRadio`) | 去广告 |
| **`Xiaohongshu.dylib`** | **小红书** (`com.xingin.discover` / `discover`) | **解锁保存别人帖子图片/视频** |

> 旧名请先移除再注入：`HiveConsumer.dylib` → `Fengchao.dylib`，`discover.dylib` → `Xiaohongshu.dylib` 等。

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
- 不破解付费墙；服务端硬拦时原生入口仍可能不出现，用悬浮按钮

## v2 性能（去广告类）
- 取消全进程类扫描（各 App 按自身实现）
- 取消 UIView 全局 swizzle
- 默认关闭日志
