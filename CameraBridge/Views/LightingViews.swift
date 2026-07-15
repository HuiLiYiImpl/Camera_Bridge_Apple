import SwiftUI
import UIKit

struct LightingLibraryView: View {
    @Binding var scenes: [LightScene]

    @State private var showingNewScene = false
    @State private var renameTargetID: UUID?
    @State private var renameText = ""
    @State private var deleteTargetID: UUID?

    var body: some View {
        NavigationStack {
            Group {
                if scenes.isEmpty {
                    emptyState
                } else {
                    sceneList
                }
            }
            .background(LightingStyle.background.ignoresSafeArea())
            .navigationTitle("屏幕补光")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewScene = true
                    } label: {
                        Label("新建场景", systemImage: "plus")
                    }
                    .tint(LightingStyle.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingNewScene) {
            LightingNewSceneView { scene in
                scenes.append(scene)
            }
        }
        .alert("重命名场景", isPresented: renamePresented) {
            TextField("场景名称", text: $renameText)
            Button("取消", role: .cancel) {
                renameTargetID = nil
            }
            Button("保存") {
                renameScene()
            }
        } message: {
            Text("名称会立即保存到场景列表。")
        }
        .confirmationDialog("删除这个补光场景？", isPresented: deletePresented, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                deleteScene()
            }
            Button("取消", role: .cancel) {
                deleteTargetID = nil
            }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private var sceneList: some View {
        List {
            Section {
                ForEach($scenes) { scene in
                    HStack(spacing: 8) {
                        NavigationLink {
                            LightingSceneEditorView(scene: scene)
                        } label: {
                            LightingSceneRow(scene: scene.wrappedValue)
                        }

                        Menu {
                            Button {
                                beginRename(scene.wrappedValue)
                            } label: {
                                Label("重命名", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deleteTargetID = scene.wrappedValue.id
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.headline)
                                .frame(width: 36, height: 36)
                                .background(.white.opacity(0.08), in: Circle())
                        }
                        .tint(.white.opacity(0.78))
                    }
                    .listRowBackground(LightingStyle.card)
                    .listRowSeparatorTint(.white.opacity(0.08))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deleteTargetID = scene.wrappedValue.id
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            beginRename(scene.wrappedValue)
                        } label: {
                            Label("重命名", systemImage: "pencil")
                        }
                        .tint(LightingStyle.accent)
                    }
                }
            } header: {
                Text("补光场景")
                    .foregroundStyle(.white.opacity(0.58))
            } footer: {
                Text("进入场景后可调整布局、每个区域的颜色与亮度，并全屏发光。")
                    .foregroundStyle(.white.opacity(0.46))
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有补光场景", systemImage: "sun.max.fill")
        } description: {
            Text("创建单色、双色或四区光场，把 iPhone 屏幕变成随身补光灯。")
        } actions: {
            Button("新建场景") {
                showingNewScene = true
            }
            .buttonStyle(.borderedProminent)
            .tint(LightingStyle.accent)
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(
            get: { renameTargetID != nil },
            set: { if !$0 { renameTargetID = nil } }
        )
    }

    private var deletePresented: Binding<Bool> {
        Binding(
            get: { deleteTargetID != nil },
            set: { if !$0 { deleteTargetID = nil } }
        )
    }

    private func beginRename(_ scene: LightScene) {
        renameTargetID = scene.id
        renameText = scene.name
    }

    private func renameScene() {
        guard let id = renameTargetID,
              let index = scenes.firstIndex(where: { $0.id == id }) else {
            renameTargetID = nil
            return
        }
        let cleanName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty {
            scenes[index].name = cleanName
        }
        renameTargetID = nil
    }

    private func deleteScene() {
        guard let id = deleteTargetID else { return }
        scenes.removeAll { $0.id == id }
        deleteTargetID = nil
    }
}

private struct LightingSceneRow: View {
    let scene: LightScene

    var body: some View {
        HStack(spacing: 14) {
            LightingCanvas(scene: scene, showsZoneNumbers: false)
                .frame(width: 76, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(.white.opacity(0.13), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(scene.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(scene.layout.title) · \(scene.layout.zoneCount) 个区域")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.56))
                Label("屏幕亮度 \(Int(scene.screenBrightness * 100))%", systemImage: "sun.max")
                    .font(.caption)
                    .foregroundStyle(LightingStyle.accent)
            }
        }
        .padding(.vertical, 7)
    }
}

private struct LightingNewSceneView: View {
    @Environment(\.dismiss) private var dismiss

    let create: (LightScene) -> Void

    @State private var name = "新补光场景"
    @State private var layout: LightLayout = .single

    var body: some View {
        NavigationStack {
            Form {
                Section("场景") {
                    TextField("场景名称", text: $name)
                }

                Section("布局") {
                    ForEach(LightLayout.allCases) { item in
                        Button {
                            layout = item
                        } label: {
                            HStack {
                                Label(item.title, systemImage: LightingDefaults.symbol(for: item))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if layout == item {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(LightingStyle.accent)
                                }
                            }
                        }
                    }
                }

                Section {
                    LightingCanvas(
                        scene: LightScene(
                            name: name,
                            layout: layout,
                            zones: LightingDefaults.zones(for: layout)
                        ),
                        showsZoneNumbers: true
                    )
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("预览")
                }
            }
            .navigationTitle("新建补光场景")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        create(LightScene(
                            name: cleanName.isEmpty ? "未命名光场" : cleanName,
                            layout: layout,
                            zones: LightingDefaults.zones(for: layout)
                        ))
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct LightingSceneEditorView: View {
    @Binding var scene: LightScene

    @State private var showingPlayback = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                preview
                sceneSettings
                layoutPicker

                ForEach(scene.zones.indices, id: \.self) { index in
                    LightingZoneEditor(zone: zoneBinding(at: index), index: index)
                }

                playbackButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 34)
        }
        .background(LightingStyle.background.ignoresSafeArea())
        .navigationTitle(scene.name)
        .navigationBarTitleDisplayMode(.inline)
        .preferredColorScheme(.dark)
        .onAppear(perform: normalizeZoneCount)
        .fullScreenCover(isPresented: $showingPlayback) {
            LightingPlaybackView(scene: scene)
        }
    }

    private var preview: some View {
        ZStack(alignment: .bottomLeading) {
            LightingCanvas(scene: scene, showsZoneNumbers: true)
                .frame(height: 330)

            LinearGradient(
                colors: [.clear, .black.opacity(0.62)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(scene.layout.title)
                    .font(.headline)
                Text("点击下方区域卡片调整光线")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(16)
        }
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(0.13), lineWidth: 1)
        }
        .padding(.top, 8)
    }

    private var sceneSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("场景设置", systemImage: "slider.horizontal.3")
                .font(.headline)

            TextField("场景名称", text: $scene.name)
                .textFieldStyle(.plain)
                .padding(.horizontal, 13)
                .frame(height: 46)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("屏幕亮度", systemImage: "sun.max")
                    Spacer()
                    Text("\(Int(scene.screenBrightness * 100))%")
                        .monospacedDigit()
                        .foregroundStyle(LightingStyle.accent)
                }
                .font(.subheadline)

                Slider(value: $scene.screenBrightness, in: 0.2...1)
                    .tint(LightingStyle.accent)
            }
        }
        .lightingCard()
    }

    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("光场布局", systemImage: "rectangle.3.group")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(LightLayout.allCases) { layout in
                    Button {
                        apply(layout: layout)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: LightingDefaults.symbol(for: layout))
                            Text(layout.title)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if scene.layout == layout {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(scene.layout == layout ? Color.black : Color.white)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(
                            scene.layout == layout ? LightingStyle.accent : .white.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .lightingCard()
    }

    private var playbackButton: some View {
        Button {
            showingPlayback = true
        } label: {
            Label("全屏发光", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.black)
        .background(LightingStyle.accent, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityHint("进入全屏补光模式，长按屏幕退出")
    }

    private func zoneBinding(at index: Int) -> Binding<LightZone> {
        Binding(
            get: {
                guard scene.zones.indices.contains(index) else { return LightZone() }
                return scene.zones[index]
            },
            set: { value in
                guard scene.zones.indices.contains(index) else { return }
                scene.zones[index] = value
            }
        )
    }

    private func normalizeZoneCount() {
        guard scene.zones.count != scene.layout.zoneCount else { return }
        apply(layout: scene.layout, force: true)
    }

    private func apply(layout: LightLayout, force: Bool = false) {
        guard force || scene.layout != layout else { return }
        let existing = scene.zones
        let defaults = LightingDefaults.zones(for: layout)
        scene.layout = layout
        scene.zones = (0..<layout.zoneCount).map { index in
            existing.indices.contains(index) ? existing[index] : defaults[index]
        }
    }
}

private struct LightingZoneEditor: View {
    @Binding var zone: LightZone
    let index: Int

    private var selectedColor: Binding<Color> {
        Binding(
            get: { zone.colorARGB.color },
            set: { zone.colorARGB = $0.argb }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(zone.colorARGB.color)
                    Circle()
                        .stroke(.white.opacity(0.32), lineWidth: 1)
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(contrastingTextColor)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("区域 \(index + 1)")
                        .font(.headline)
                    Text("独立颜色、亮度与边界柔和度")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                ColorPicker("区域 \(index + 1) 颜色", selection: selectedColor, supportsOpacity: false)
                    .labelsHidden()
            }

            LightingValueSlider(
                title: "区域亮度",
                symbol: "light.max",
                value: $zone.intensity,
                range: 0...1
            )

            LightingValueSlider(
                title: "柔和度",
                symbol: "aqi.medium",
                value: $zone.softness,
                range: 0...1
            )
        }
        .lightingCard()
    }

    private var contrastingTextColor: Color {
        let value = zone.colorARGB
        let red = Double((value >> 16) & 0xFF)
        let green = Double((value >> 8) & 0xFF)
        let blue = Double(value & 0xFF)
        return red * 0.299 + green * 0.587 + blue * 0.114 > 160 ? .black : .white
    }
}

private struct LightingValueSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(Int(value * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(LightingStyle.accent)
            }
            .font(.subheadline)

            Slider(value: $value, in: range)
                .tint(LightingStyle.accent)
        }
    }
}

private struct LightingCanvas: View {
    let scene: LightScene
    var showsZoneNumbers = false

    private var zones: [LightZone] {
        let defaults = LightingDefaults.zones(for: scene.layout)
        return (0..<scene.layout.zoneCount).map { index in
            scene.zones.indices.contains(index) ? scene.zones[index] : defaults[index]
        }
    }

    var body: some View {
        ZStack {
            Color.black
            layoutContent
        }
        .clipped()
        .drawingGroup(opaque: true, colorMode: .linear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(scene.name)，\(scene.layout.title)")
    }

    @ViewBuilder
    private var layoutContent: some View {
        switch scene.layout {
        case .single:
            LightingZoneFill(zone: zones[0], number: showsZoneNumbers ? 1 : nil)
        case .leftRight:
            HStack(spacing: 0) {
                LightingZoneFill(zone: zones[0], number: showsZoneNumbers ? 1 : nil)
                LightingZoneFill(zone: zones[1], number: showsZoneNumbers ? 2 : nil)
            }
        case .topBottom:
            VStack(spacing: 0) {
                LightingZoneFill(zone: zones[0], number: showsZoneNumbers ? 1 : nil)
                LightingZoneFill(zone: zones[1], number: showsZoneNumbers ? 2 : nil)
            }
        case .four:
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    LightingZoneFill(zone: zones[0], number: showsZoneNumbers ? 1 : nil)
                    LightingZoneFill(zone: zones[1], number: showsZoneNumbers ? 2 : nil)
                }
                HStack(spacing: 0) {
                    LightingZoneFill(zone: zones[2], number: showsZoneNumbers ? 3 : nil)
                    LightingZoneFill(zone: zones[3], number: showsZoneNumbers ? 4 : nil)
                }
            }
        }
    }
}

private struct LightingZoneFill: View {
    let zone: LightZone
    let number: Int?

    var body: some View {
        GeometryReader { geometry in
            let edge = min(geometry.size.width, geometry.size.height)
            let softness = zone.softness.clamped(to: 0...1)

            ZStack {
                Rectangle()
                    .fill(zone.colorARGB.color.opacity(zone.intensity.clamped(to: 0...1)))
                    .scaleEffect(1 + softness * 0.12)
                    .blur(radius: softness * edge * 0.13)

                if let number {
                    Text("\(number)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(7)
                        .background(.black.opacity(0.42), in: Circle())
                        .overlay {
                            Circle().stroke(.white.opacity(0.3), lineWidth: 1)
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

private struct LightingPlaybackView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let scene: LightScene

    @State private var originalBrightness: CGFloat?
    @State private var originalIdleTimerDisabled: Bool?
    @State private var showingHint = true

    var body: some View {
        ZStack {
            LightingCanvas(scene: scene, showsZoneNumbers: false)
                .ignoresSafeArea()

            if showingHint {
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill")
                        .font(.title2)
                    Text(scene.name)
                        .font(.headline)
                    Text("长按屏幕退出发光模式")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 32) {
            dismiss()
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear(perform: captureAndApplyPlaybackState)
        .onDisappear(perform: restorePlaybackState)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                applyPlaybackState()
            case .inactive, .background:
                restorePlaybackState()
            @unknown default:
                restorePlaybackState()
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(2.3))
            withAnimation(.easeOut(duration: 0.25)) {
                showingHint = false
            }
        }
        .preferredColorScheme(.dark)
        .accessibilityAction(named: "退出发光模式") {
            dismiss()
        }
    }

    private func captureAndApplyPlaybackState() {
        if originalBrightness == nil {
            originalBrightness = UIScreen.main.brightness
        }
        if originalIdleTimerDisabled == nil {
            originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        applyPlaybackState()
    }

    private func applyPlaybackState() {
        UIScreen.main.brightness = CGFloat(scene.screenBrightness.clamped(to: 0.2...1))
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func restorePlaybackState() {
        if let originalBrightness {
            UIScreen.main.brightness = originalBrightness
        }
        if let originalIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = originalIdleTimerDisabled
        }
    }
}

private enum LightingDefaults {
    static func symbol(for layout: LightLayout) -> String {
        switch layout {
        case .single: "rectangle.fill"
        case .leftRight: "rectangle.split.2x1"
        case .topBottom: "rectangle.split.1x2"
        case .four: "square.grid.2x2"
        }
    }

    static func zones(for layout: LightLayout) -> [LightZone] {
        let colors: [UInt32]
        switch layout {
        case .single:
            colors = [0xFFFFE4C2]
        case .leftRight, .topBottom:
            colors = [0xFFFFB26B, 0xFF78BFFF]
        case .four:
            colors = [0xFFFFB26B, 0xFFFF7F9D, 0xFF8BC7FF, 0xFFBBA2FF]
        }
        return colors.map { LightZone(colorARGB: $0, intensity: 1, softness: 0.2) }
    }
}

private enum LightingStyle {
    static let accent = Color(red: 1, green: 0.44, blue: 0.2)
    static let card = Color.white.opacity(0.065)
    static let background = LinearGradient(
        colors: [Color(red: 0.18, green: 0.055, blue: 0.075), Color(red: 0.045, green: 0.03, blue: 0.045), .black],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

private extension View {
    func lightingCard() -> some View {
        self
            .padding(16)
            .background(LightingStyle.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
