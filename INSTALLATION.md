# 未上架安装与测试说明

Camera Bridge 未上架 App Store 时，可通过 Xcode、TestFlight 或 Ad Hoc 安装。三种方式不会改变 App 功能，但签名、安装对象和更新流程不同。

## 方式选择

| 方式 | 适合场景 | 是否需要付费 Apple Developer Program | 是否需要 Mac/Xcode |
| --- | --- | --- | --- |
| Xcode 真机直装 | 开发者自己或身边少量设备快速测试 | 可使用个人 Apple Account；付费团队更稳定 | 安装时需要 |
| TestFlight | 异地、多人的持续内测和自动更新 | 需要 | 上传构建时需要 |
| Ad Hoc IPA | 少量已登记设备离线安装 | 需要 | 制作和签名 IPA 时需要 |

推荐顺序：先用 Xcode 在自己的 iPhone 上验证相机连接，再用 TestFlight 发给其他测试人员。

## 一、Xcode 真机直装（最简单）

### 准备

- 一台 Mac 和当前版本 Xcode。
- iPhone 或 iPad、数据线，或已与 Xcode 配对的无线设备。
- 一个 Apple Account。打开 `Xcode > Settings > Accounts` 登录。
- 首次配对时，在设备上信任这台 Mac，并根据系统提示打开：
  `设置 > 隐私与安全性 > 开发者模式`，重启后再次确认。

### 获取并生成工程

```bash
git clone https://github.com/HuiLiYiImpl/Camera_Bridge_Apple.git
cd Camera_Bridge_Apple
brew install xcodegen
xcodegen generate
open CameraBridge.xcodeproj
```

如果已经克隆仓库，只需拉取并重新生成工程：

```bash
git pull
xcodegen generate
open CameraBridge.xcodeproj
```

### 配置签名并安装

1. 在 Xcode 左侧选择项目 `CameraBridge`，再选择 TARGETS 下的 `CameraBridge`。
2. 打开 `Signing & Capabilities`。
3. 勾选 `Automatically manage signing`，在 `Team` 中选择自己的个人团队或开发者团队。
4. 如果提示 Bundle Identifier 已被占用，把 `com.huiliyi.CameraBridge` 改为自己唯一的值，例如 `com.yourname.CameraBridge`。使用 XcodeGen 时，建议同时修改 `project.yml` 中的 `PRODUCT_BUNDLE_IDENTIFIER`，再执行 `xcodegen generate`。
5. 用数据线连接设备，在 Xcode 顶部运行目标中选择这台 iPhone / iPad。
6. 点击运行按钮，或按 `Command-R`。Xcode 会完成签名、安装并启动 App。
7. 如果设备提示开发者不受信任，按系统显示的开发者名称前往设备管理页面完成信任；新版系统通常会通过开发者模式和首次启动提示引导完成。

个人免费团队签名的构建可能需要定期重新连接 Xcode 安装；需要长期、多人测试时使用 TestFlight。

### 首次权限与相机测试

1. 允许“本地网络”和“照片”权限。
2. Wi-Fi 测试：先在 iPhone 系统 Wi-Fi 设置中加入相机热点，再在 App 中连接默认的 `192.168.1.1:15740`。
3. USB 测试：使用支持数据传输的线缆，把相机 USB 模式设为 PTP/MTP，然后连接 iPhone / iPad。
4. 建议依次验证：空卡、分页、JPG/RAW/视频筛选、队列取消与重试、LUT/水印导出、系统照片保存、锁屏/切后台、拔线重连和大视频空间提示。

> ImageCaptureCore 的 USB 相机发现不受 iOS 模拟器支持，模拟器只适合检查普通 UI、模型和不依赖外设的功能。

## 二、TestFlight 内测（推荐给异地测试者）

TestFlight 不要求 App 已在 App Store 正式上架，但需要有效的 Apple Developer Program 会员和 App Store Connect 权限。

### 上传构建

1. 在 Apple Developer / App Store Connect 创建与 Bundle Identifier 对应的 App ID 和 App 记录。
2. 在 `project.yml` 或 Xcode 中选择付费开发者 Team，并确保版本号与构建号有效；每次重新上传时递增 `CURRENT_PROJECT_VERSION`。
3. 执行 `xcodegen generate`，在 Xcode 打开工程。
4. 运行目标选择 `Any iOS Device (arm64)` 或真实设备。
5. 选择 `Product > Archive`。
6. Archive 完成后，在 Organizer 中选择 `Distribute App > App Store Connect > Upload`，按提示验证并上传。
7. 等待 App Store Connect 处理完成，在应用的 `TestFlight` 页面把构建加入测试组。

### 测试人员安装

1. 测试人员从 App Store 安装 Apple 的 TestFlight。
2. 打开邀请邮件或公开邀请链接并接受测试。
3. 在 TestFlight 中安装 Camera Bridge；新构建发布后也从 TestFlight 更新。

内部测试最多可添加 100 名有 App Store Connect 权限的用户；外部测试最多 10,000 人，首个外部测试构建通常需要 Beta App Review。每个 TestFlight 构建最多可测试 90 天。

## 三、Ad Hoc IPA（登记设备离线安装）

Ad Hoc 仅能安装到描述文件中预先登记 UDID 的设备，适合固定的少量测试机。

### 制作 IPA

1. 在 Apple Developer 后台登记每台测试设备的 UDID。
2. 准备对应 Bundle Identifier 的 App ID、Apple Distribution 证书和 Ad Hoc provisioning profile；也可以让 Xcode自动管理部分签名工作。
3. 在 Xcode 选择 `Product > Archive`。
4. 在 Organizer 选择 `Distribute App > Ad Hoc` 或 `Release Testing`（名称随 Xcode 版本可能略有变化）。
5. 选择正确团队和描述文件，导出 `.ipa`。

### 安装 IPA

- 将设备连接 Mac，使用 Apple Configurator 安装签名后的 IPA；或通过组织的 MDM/受控分发工具安装。
- 设备必须包含在 Ad Hoc 描述文件中，并可能需要启用开发者模式。
- 新增设备、证书变化或描述文件过期后，需要重新生成描述文件、重新签名并导出 IPA。

不要把开发证书私钥、`.p12` 密码、签名描述文件或 App Store Connect API Key 提交到 Git 仓库。

## 模拟器安装

模拟器无需开发者签名：

```bash
xcodegen generate
xcodebuild -project CameraBridge.xcodeproj \
  -scheme CameraBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  CODE_SIGNING_ALLOWED=NO build
```

也可以直接在 Xcode 选择一个 iPhone Simulator 后按 `Command-R`。模拟器无法验证 USB 外接相机、真实相机热点保持、PhotoKit 真机授权、锁屏后台时限和真实设备性能。

## 常见问题

### Signing requires a development team

在 `Signing & Capabilities > Team` 选择自己的团队，并保持自动签名开启。

### Bundle Identifier is not available

把 Bundle Identifier 改为自己账户下唯一的反向域名。若修改 `project.yml`，记得重新执行 `xcodegen generate`。

### Developer Mode disabled

先让 Xcode 与设备配对，然后在设备的 `设置 > 隐私与安全性 > 开发者模式` 中开启，按提示重启和确认。

### App 安装后打不开或提示无法验证

确认设备联网、签名证书和描述文件仍有效、设备 UDID 已登记；个人团队构建可重新用 Xcode 安装，TestFlight 构建可检查是否已超过 90 天。

### USB 页面提示模拟器不支持

这是预期行为。请选择真实 iPhone / iPad，并使用支持数据的线缆连接相机。

## Apple 官方参考

- [在模拟器或真机运行 App](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)
- [开启 Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [TestFlight 概览](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [创建 Ad Hoc provisioning profile](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile)
