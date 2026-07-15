import SwiftUI
import UIKit

struct CameraScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette
    let openGallery: () -> Void
    let openSettings: () -> Void
    @State private var connectionSheet: CameraTransport?
    @State private var showingLighting = false
    @State private var confirmDisconnect = false

    var body: some View {
        ZStack {
            palette.night.ignoresSafeArea()
            if let session = model.session { connected(session) }
            else { landing }
        }
        .navigationTitle(model.session == nil ? "Camera Bridge" : "相机")
        .toolbarBackground(palette.night, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: openSettings) { Image(systemName: "gearshape") }
            }
        }
        .sheet(item: $connectionSheet) { transport in
            if transport == .wifi { WiFiConnectionSheet() }
            else { USBConnectionSheet(usb: model.usbClient) }
        }
        .sheet(isPresented: $showingLighting) { NavigationStack { LightingLibraryView(scenes: $model.lightScenes) } }
        .confirmationDialog("下载或读取尚未完成，仍要断开吗？", isPresented: $confirmDisconnect) {
            Button("断开连接", role: .destructive, action: model.disconnect)
            Button("取消", role: .cancel) {}
        }
    }

    private var landing: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image("CameraBridgeLogo")
                    .resizable().scaledToFit().frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .shadow(color: palette.accent.opacity(0.25), radius: 28)
                VStack(spacing: 5) {
                    Text("连接你的相机").font(.largeTitle.bold())
                    Text("原片、色彩与创作工作流，都在一处").foregroundStyle(palette.text.opacity(0.58))
                }
                .foregroundStyle(palette.text)
                HStack(spacing: 12) {
                    connectionCard(.wifi, subtitle: "Nikon PTP/IP", action: { connectionSheet = .wifi })
                    connectionCard(.usb, subtitle: "Image Capture", action: { connectionSheet = .usb })
                }
                if !model.config.lastCameraName.isEmpty {
                    HStack {
                        Image(systemName: model.config.lastTransport.symbol).foregroundStyle(palette.accent)
                        VStack(alignment: .leading) {
                            Text("最近连接").font(.caption).foregroundStyle(palette.text.opacity(0.5))
                            Text(model.config.lastCameraName).font(.subheadline.bold())
                        }
                        Spacer()
                        Button("重新连接") {
                            if model.config.lastTransport == .wifi { model.connectWiFi() }
                            else { connectionSheet = .usb }
                        }
                    }
                    .foregroundStyle(palette.text).bridgeCard()
                }
                Button { showingLighting = true } label: {
                    HStack {
                        Image(systemName: "lightbulb.max.fill").foregroundStyle(palette.accent).font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("屏幕补光").font(.headline)
                            Text("创建并播放单色、双色或四区光场").font(.caption).foregroundStyle(palette.text.opacity(0.56))
                        }
                        Spacer(); Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(palette.text)
                }
                .buttonStyle(.plain).bridgeCard()
                if case .error(let message) = model.workflow {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("连接诊断", systemImage: "stethoscope").font(.headline).foregroundStyle(palette.accent)
                        Text(message).font(.caption).foregroundStyle(palette.text.opacity(0.72))
                        HStack {
                            Button("复制错误") { UIPasteboard.general.string = message }
                            Spacer()
                            Button("打开设置") { openSystemSettings() }
                        }
                    }
                    .bridgeCard()
                }
            }
            .padding(20).padding(.bottom, 90)
        }
    }

    private func connectionCard(_ transport: CameraTransport, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                Image(systemName: transport.symbol).font(.title).foregroundStyle(palette.accent)
                Spacer(minLength: 14)
                Text(transport.title).font(.title3.bold())
                Text(subtitle).font(.caption).foregroundStyle(palette.text.opacity(0.52))
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
            .foregroundStyle(palette.text)
        }
        .buttonStyle(.plain).bridgeCard()
    }

    private func connected(_ session: CameraSession) -> some View {
        ScrollView {
            VStack(spacing: 15) {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(palette.accent.opacity(0.13)).frame(width: 82, height: 82)
                        Image(systemName: "camera.fill").font(.system(size: 32)).foregroundStyle(palette.accent)
                    }
                    Text(session.name).font(.title.bold())
                    Text([session.details.manufacturer, session.details.lensName ?? session.details.lensSpecification].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(palette.text.opacity(0.55))
                }
                .foregroundStyle(palette.text)
                HStack(spacing: 10) {
                    metric("照片", "\(model.photos.count)", "photo.stack")
                    metric("电量", session.details.batteryPercent.map { "\($0)%" } ?? "--", "battery.75percent")
                    metric("连接", session.transport.title, session.transport.symbol)
                }
                if let recent = recentSettings(session.details) {
                    HStack {
                        Image(systemName: "camera.aperture").foregroundStyle(palette.accent)
                        VStack(alignment: .leading) {
                            Text("最近拍摄参数").font(.caption).foregroundStyle(palette.text.opacity(0.48))
                            Text(recent).font(.subheadline)
                        }
                        Spacer()
                    }
                    .foregroundStyle(palette.text).bridgeCard()
                }
                Button(action: openGallery) {
                    Label("进入相册", systemImage: "photo.on.rectangle.angled")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 18)).foregroundStyle(palette.night)
                }
                .disabled(model.isBusy || model.photos.isEmpty)
                Button { showingLighting = true } label: {
                    Label("屏幕补光工具", systemImage: "lightbulb.max.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                if session.details.deviceVersion != nil || session.details.serialNumber != nil {
                    VStack(spacing: 0) {
                        if let value = session.details.deviceVersion { infoRow("固件版本", value) }
                        if let value = session.details.serialNumber { infoRow("序列号", "•••• \(value.suffix(4))") }
                        if let value = session.details.recentCapturedAt { infoRow("最近拍摄", value.bridgeDateText) }
                    }
                    .bridgeCard()
                }
                HStack(spacing: 12) {
                    Button(action: model.refresh) { Label("重新读取", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large).disabled(model.isBusy)
                    Button(role: .destructive) {
                        if model.isBusy { confirmDisconnect = true } else { model.disconnect() }
                    } label: { Label("断开", systemImage: "link.badge.minus").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }
            .padding(20).padding(.bottom, 90)
        }
    }

    private func metric(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol).foregroundStyle(palette.accent)
            Text(value).font(.headline).lineLimit(1)
            Text(label).font(.caption2).foregroundStyle(palette.text.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(palette.text).bridgeCard()
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(palette.text.opacity(0.5)); Spacer(); Text(value) }
            .font(.subheadline).foregroundStyle(palette.text).padding(.vertical, 6)
    }

    private func recentSettings(_ details: CameraDetails) -> String? {
        let values = [details.recentFocalLength, details.recentAperture, details.recentShutter, details.recentISO.map { "ISO \($0)" }].compactMap { $0 }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

struct WiFiConnectionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.bridgePalette) private var palette

    var body: some View {
        NavigationStack {
            Form {
                Section("相机品牌") {
                    Picker("品牌", selection: $model.config.brand) {
                        ForEach(CameraBrand.allCases) { brand in
                            Text(brand.available ? brand.title : "\(brand.title) · 即将支持").tag(brand)
                        }
                    }
                }
                Section("三步连接") {
                    step(1, "在相机上选择“连接到智能设备”")
                    step(2, "选择 AP mode，并在系统 Wi-Fi 设置加入相机热点")
                    step(3, "返回 Camera Bridge 建立 PTP/IP 会话")
                    Button("打开 Camera Bridge 设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Section("PTP/IP") {
                    TextField("相机地址", text: $model.config.host).textInputAutocapitalization(.never).keyboardType(.numbersAndPunctuation)
                    TextField("端口", value: $model.config.port, format: .number).keyboardType(.numberPad)
                }
                Section {
                    Button {
                        model.connectWiFi(); dismiss()
                    } label: { Label("开始建立连接", systemImage: "link").frame(maxWidth: .infinity) }
                    .disabled(model.config.brand != .nikon || model.isBusy)
                }
            }
            .scrollContentBackground(.hidden).background(palette.night)
            .navigationTitle("Wi-Fi 连接").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: dismiss.callAsFunction) } }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top) {
            Text("\(number)").font(.caption.bold()).frame(width: 26, height: 26).background(palette.accent, in: Circle()).foregroundStyle(palette.night)
            Text(text).font(.subheadline)
        }
    }
}

struct USBConnectionSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var usb: ImageCaptureCameraClient
    @Environment(\.dismiss) private var dismiss
    @Environment(\.bridgePalette) private var palette

    var body: some View {
        NavigationStack {
            List {
                Section("USB 相机") {
                    if usb.discoveredCameras.isEmpty {
                        ContentUnavailableView("尚未检测到相机", systemImage: "cable.connector.slash", description: Text("使用数据线连接相机，并将 USB 模式设为 PTP 或 MTP。"))
                    } else {
                        ForEach(usb.discoveredCameras) { camera in
                            Button {
                                model.connectUSB(camera); dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "camera.fill").foregroundStyle(palette.accent)
                                    VStack(alignment: .leading) {
                                        Text(camera.name)
                                        Text(camera.productKind ?? "外接相机").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName: "chevron.right")
                                }
                            }
                        }
                    }
                    Button { model.startUSBDiscovery() } label: {
                        Label(usb.discoveredCameras.isEmpty ? "开始检测" : "重新检测", systemImage: "arrow.clockwise")
                    }
                }
                Section("排障") {
                    Label("使用支持数据传输的 USB-C 线缆或相机适配器", systemImage: "cable.connector")
                    Label("相机应开启且处于 PTP/MTP，而不是仅充电", systemImage: "camera.badge.ellipsis")
                    Label("首次访问会显示系统外接相机权限提示", systemImage: "hand.raised")
                }
                .font(.subheadline)
            }
            .scrollContentBackground(.hidden).background(palette.night)
            .navigationTitle("USB 连接").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭", action: dismiss.callAsFunction) } }
            .task { if usb.discoveredCameras.isEmpty { model.startUSBDiscovery() } }
        }
    }
}
