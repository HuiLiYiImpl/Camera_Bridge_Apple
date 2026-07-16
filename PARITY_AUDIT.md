# Android / Apple 功能对齐审计

对照来源：Android `README.md`、`TEST_PLAN.md`、Compose 页面和灯光模型；Apple 端以原生 SwiftUI、Network、ImageCaptureCore、Core Image、AVFoundation、PhotoKit 实现同等用户流程。

| 模块 | Apple 实现与验证 |
| --- | --- |
| Wi-Fi PTP/IP | 设备会话、分页对象读取、自适应分块、断线检查、自动恢复开关、诊断日志均已实现。iOS 不能提供 Android Wi-Fi Lock 的永久后台语义。 |
| USB | 使用 Apple 公共 ImageCaptureCore API 自动发现、授权、分页和下载；模拟器明确提示不可用，避免调用系统不存在的授权选择器。需真机与相机验证兼容性。 |
| 相册 | 全部/JPG/RAW/视频筛选、多选、分页、缩略图缓存、原图预览、旋转及下载；筛选页会继续拉取后续页，空卡也可进入相册。 |
| 下载队列 | 防重复、串行队列、等待/下载/取消中/失败状态、未知总量不定进度、速度、剩余量、ETA、取消确认、重试、离线查看、批量分享和删除。 |
| LUT / 水印 | `.cube`、Hald `.png`、`.xmp`，照片/视频预览、强度、旋转、EXIF 水印、品牌 Logo、单个和批量组合导出。 |
| 视频 | AVFoundation 有声播放、进度拖动、旋转、保留音轨的硬件导出；导出前检查所需/可用空间，失败或取消清理半成品，并申请有限后台执行时间。 |
| 自动导出 | JPG/视频下载、单项编辑和批量编辑路径统一遵守“加入系统照片图库”开关；RAW 保留在 Files，原文件始终先保存在 App Documents。 |
| 屏幕补光 | 递归自由布局，最多 8 区；选区分割/合并、拖动比例、30 步撤销、跨区渐变柔化、区域颜色/亮度/柔和度、全局柔和度、编辑页实时屏幕亮度和全屏播放状态恢复。 |
| 设置 / 诊断 / 外观 | Wi-Fi 自动恢复、USB 自动读取、缓存与清理、JPEG 质量、自动导出、四套主题、诊断复制/导出/清理。 |
| 资源与版本 | App Icon、应用 Logo、品牌 Logo、两套字体和隐私清单均进入 Copy Bundle Resources；构建版本为 2.0.0 (1)。 |

## 自动化结果

- XcodeGen 工程可生成。
- iPhone 17 Pro / iOS 26.5 Simulator 的 application build 与 XCTest 通过。
- 覆盖 PTP 协议、自适应分块、LUT、水印、旧设置迁移、灯光树分割/合并/比例/持久化、存储估算和 Bundle 资源。
- 模拟器冷启动并截图验证首页 Logo、字体和布局加载正常。

## 真机验收边界

以下能力依赖外设、系统授权或真实存储压力，不能由模拟器替代：Nikon Zf 的 Wi-Fi/USB 端到端传输、拔线重连、锁屏后的 iOS 后台时限、系统照片授权、超过 1 GB 的有声视频导出及空间不足场景。执行 Android `TEST_PLAN.md` 的 B 组时，应在 iPhone 上采用同样素材逐项复验。
