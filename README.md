# Camera Bridge for Apple

Camera Bridge 是使用 **SwiftUI、Network、Core Image、AVFoundation、PhotoKit** 重写的原生 iPhone / iPad 相机桥接工具。它保留原 Android 版本的 Nikon PTP/IP 浏览与下载协议，以及相册、下载队列、LUT、水印、视频导出、屏幕灯光和诊断能力。

## 功能

- Nikon Wi-Fi (PTP/IP) 连接，读取设备、镜头、电量与媒体信息
- 分页相册、JPG / RAW / 视频筛选、缩略图、原图预览与多选下载
- 自适应 1–8 MiB 分块、失败退避、取消、重试、速度和 ETA
- 下载文件保存在 App 的 Documents/CameraBridge，并可自动加入系统照片图库
- `.cube`、Hald CLUT `.png` 与 Adobe `.xmp` LUT 导入
- Core Image 实时照片预览，AVFoundation 视频预览与硬件导出
- EXIF 水印模板、批量 LUT / 水印处理和系统分享
- 最多八区的自由屏幕灯光场景，支持分割、合并、拖动比例、撤销、柔和度、亮度控制与本地保存
- 连接/下载诊断日志导出
- 暗房橙、尼康黄、专业灰、深海蓝四套主题

## 平台说明

Apple 版同时使用 Nikon Wi-Fi PTP/IP 和 `ImageCaptureCore` 外接相机接口。USB 模式通过 `ICDeviceBrowser`、`ICCameraDevice` 与 `ICCameraFile` 浏览和下载相机媒体，不依赖私有 USB API；具体 Nikon 机型、线缆和相机 USB 模式仍需真机验证。`ExternalAccessory` 不是通用相机 MTP/PTP 接口，因此本项目不使用它。

iOS 也不允许第三方 App 永久锁定相机 Wi-Fi 或在后台无限维持任意 TCP 连接。Camera Bridge 会在前台和有限后台任务期内保持传输，并在回到前台时检查会话。

## 构建

要求：macOS、Xcode 16+、XcodeGen。

```bash
brew install xcodegen
./scripts/bootstrap.sh
```

也可以直接运行：

```bash
xcodegen generate
xcodebuild -project CameraBridge.xcodeproj \
  -scheme CameraBridge \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=NO test
```

真机运行前，在 Xcode 的 Signing & Capabilities 中选择自己的 Team。首次连接时允许“本地网络”权限，并先在系统设置中加入相机创建的 Wi-Fi 热点。

## 使用

1. 在 Nikon 相机中选择“连接到智能设备”并启用 AP mode。
2. 在 iPhone / iPad 的 Wi-Fi 设置中加入相机热点。
3. 打开 Camera Bridge，默认地址 `192.168.1.1:15740`，点击“建立 Wi-Fi 连接”。
4. 进入“照片”分页浏览、预览和创建下载任务。
5. 在“下载”页分享、删除或对本地媒体应用 LUT / 水印。

## 工程结构

```text
CameraBridge/App            App 入口与全局模型
CameraBridge/Models         领域模型与持久化数据
CameraBridge/Services       PTP/IP、下载、LUT、水印、视频、诊断
CameraBridge/Views          SwiftUI 页面与组件
CameraBridge/Resources      App 图标和品牌素材
CameraBridgeTests           协议、解析与模型测试
project.yml                 XcodeGen 工程定义
```

## 已知硬件测试状态

原协议实现已在 Android 版用 Nikon Zf 验证。Apple 重写保留相同的 PTP/IP 初始化 GUID、操作码、分页顺序与自适应分块策略；模拟器构建和自动化测试已通过。USB、相机 Wi-Fi、后台时限及大于 1 GB 视频仍建议在 Nikon Zf 与 iPhone 真机上完成端到端验收后再发布 App Store。
