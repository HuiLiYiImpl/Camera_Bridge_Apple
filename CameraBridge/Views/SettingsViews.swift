import SwiftUI
import UIKit

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette
    @State private var diagnosticsURL: URL?
    @State private var showingDiagnosticsShare = false

    var body: some View {
        Form {
            Section("外观") {
                Picker("配色主题", selection: $model.config.colorTheme) {
                    ForEach(AppColorTheme.allCases) { theme in
                        VStack(alignment: .leading) { Text(theme.title); Text(theme.subtitle) }.tag(theme)
                    }
                }
                .pickerStyle(.navigationLink)
                themePreview
            }
            Section {
                Picker("相机品牌", selection: $model.config.brand) { ForEach(CameraBrand.allCases) { Text($0.title + ($0.available ? "" : " · 即将支持")).tag($0) } }
                TextField("PTP/IP 地址", text: $model.config.host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.numbersAndPunctuation)
                TextField("端口", value: $model.config.port, format: .number).keyboardType(.numberPad)
                Toggle("传输期间保持屏幕常亮", isOn: $model.config.keepWiFiAlive)
            } header: {
                Text("连接")
            } footer: {
                Text("iOS 不允许第三方 App 永久锁定 Wi-Fi；相机下载进入后台后只能获得有限收尾时间。")
            }
            Section {
                Toggle("下载后加入系统照片图库", isOn: $model.config.autoExport)
                Stepper("JPEG 质量 \(model.config.jpegQuality)%", value: $model.config.jpegQuality, in: 70 ... 100)
                TextField("文件命名规则", text: $model.config.fileNamingRule)
                Toggle("启用缩略图缓存", isOn: $model.config.thumbnailCacheEnabled)
                Button("清理缩略图缓存", action: model.clearThumbnailCache)
            } header: {
                Text("下载与导出")
            } footer: {
                Text("所有文件先保存在“文件 > 我的 iPhone/iPad > Camera Bridge”；加入照片图库后会产生独立副本。")
            }
            Section("诊断") {
                Button {
                    Task { UIPasteboard.general.string = await model.diagnosticText(); model.notice = "诊断内容已复制" }
                } label: { Label("复制诊断文本", systemImage: "doc.on.doc") }
                Button {
                    Task {
                        diagnosticsURL = await model.exportDiagnostics()
                        showingDiagnosticsShare = diagnosticsURL != nil
                    }
                } label: { Label("导出诊断包", systemImage: "square.and.arrow.up") }
                Button("清除诊断数据", role: .destructive, action: model.clearDiagnostics)
            }
            Section("关于") {
                LabeledContent("应用", value: "Camera Bridge")
                LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0.0")
                LabeledContent("技术", value: "SwiftUI · PTP/IP · ImageCaptureCore")
                Link("Apple ImageCaptureCore 文档", destination: URL(string: "https://developer.apple.com/documentation/imagecapturecore")!)
                Text("Camera Bridge 与 Nikon Corporation 不存在隶属或背书关系。相机品牌名称和 Logo 归各自权利人所有。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden).background(palette.night)
        .navigationTitle("设置")
        .toolbarBackground(palette.night, for: .navigationBar)
        .sheet(isPresented: $showingDiagnosticsShare) {
            if let diagnosticsURL { ShareSheet(items: [diagnosticsURL]) }
        }
    }

    private var themePreview: some View {
        let preview = BridgePalette.palette(for: model.config.colorTheme)
        return HStack(spacing: 0) {
            preview.night.frame(maxWidth: .infinity)
            preview.surface.frame(maxWidth: .infinity)
            preview.accent.frame(maxWidth: .infinity)
            preview.text.frame(maxWidth: .infinity)
        }
        .frame(height: 36).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
