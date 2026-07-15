import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case camera, photos, downloads, lut, settings
    var id: Self { self }
    var title: String {
        switch self {
        case .camera: "相机"
        case .photos: "照片"
        case .downloads: "下载"
        case .lut: "LUT"
        case .settings: "设置"
        }
    }
    var symbol: String {
        switch self {
        case .camera: "camera.fill"
        case .photos: "photo.on.rectangle.angled"
        case .downloads: "arrow.down.circle.fill"
        case .lut: "camera.filters"
        case .settings: "gearshape.fill"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab: AppTab = .camera
    @State private var showingAlert = false

    var body: some View {
        let palette = BridgePalette.palette(for: model.config.colorTheme)
        TabView(selection: $selectedTab) {
            NavigationStack { CameraScreen(openGallery: { selectedTab = .photos }, openSettings: { selectedTab = .settings }) }
                .tag(AppTab.camera).tabItem { Label(AppTab.camera.title, systemImage: AppTab.camera.symbol) }
            NavigationStack { GalleryScreen() }
                .tag(AppTab.photos).tabItem { Label(AppTab.photos.title, systemImage: AppTab.photos.symbol) }
            NavigationStack { DownloadsScreen() }
                .tag(AppTab.downloads).tabItem { Label(AppTab.downloads.title, systemImage: AppTab.downloads.symbol) }
                .badge(model.activeDownloadCount)
            NavigationStack { LUTLibraryScreen() }
                .tag(AppTab.lut).tabItem { Label(AppTab.lut.title, systemImage: AppTab.lut.symbol) }
            NavigationStack { SettingsScreen() }
                .tag(AppTab.settings).tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.symbol) }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ActivityPill() }
        .environment(\.bridgePalette, palette)
        .tint(palette.accent)
        .preferredColorScheme(.dark)
        .background(palette.night.ignoresSafeArea())
        .onChange(of: model.session) { _, session in if session == nil { selectedTab = .camera } }
        .onChange(of: model.alertMessage) { _, value in showingAlert = value != nil }
        .alert("Camera Bridge", isPresented: $showingAlert) {
            Button("好") { model.alertMessage = nil }
        } message: { Text(model.alertMessage ?? "") }
    }
}
