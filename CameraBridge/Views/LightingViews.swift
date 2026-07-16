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
                    ContentUnavailableView {
                        Label("还没有补光场景", systemImage: "sun.max.fill")
                    } description: {
                        Text("创建场景，把 iPhone 屏幕变成最多八区的随身补光灯。")
                    } actions: {
                        Button("新建场景") { showingNewScene = true }
                            .buttonStyle(.borderedProminent).tint(LightingStyle.accent)
                    }
                } else {
                    List {
                        Section("补光场景") {
                            ForEach($scenes) { scene in
                                HStack(spacing: 8) {
                                    NavigationLink {
                                        LightingSceneEditorView(scene: scene)
                                    } label: {
                                        LightingSceneRow(scene: scene.wrappedValue)
                                    }
                                    Menu {
                                        Button("重命名", systemImage: "pencil") { beginRename(scene.wrappedValue) }
                                        Button("删除", systemImage: "trash", role: .destructive) {
                                            deleteTargetID = scene.wrappedValue.id
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis").frame(width: 36, height: 36)
                                            .background(.white.opacity(0.08), in: Circle())
                                    }
                                }
                                .listRowBackground(LightingStyle.card)
                                .swipeActions(allowsFullSwipe: false) {
                                    Button("删除", systemImage: "trash", role: .destructive) { deleteTargetID = scene.wrappedValue.id }
                                    Button("重命名", systemImage: "pencil") { beginRename(scene.wrappedValue) }
                                        .tint(LightingStyle.accent)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(LightingStyle.background.ignoresSafeArea())
            .navigationTitle("屏幕补光")
            .toolbar {
                Button("新建场景", systemImage: "plus") { showingNewScene = true }
                    .tint(LightingStyle.accent)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingNewScene) {
            LightingNewSceneView { scenes.append($0) }
        }
        .alert("重命名场景", isPresented: renamePresented) {
            TextField("场景名称", text: $renameText)
            Button("取消", role: .cancel) { renameTargetID = nil }
            Button("保存", action: renameScene)
        }
        .confirmationDialog("删除这个补光场景？", isPresented: deletePresented) {
            Button("删除", role: .destructive, action: deleteScene)
            Button("取消", role: .cancel) { deleteTargetID = nil }
        } message: { Text("删除后无法恢复。") }
    }

    private var renamePresented: Binding<Bool> { .init(get: { renameTargetID != nil }, set: { if !$0 { renameTargetID = nil } }) }
    private var deletePresented: Binding<Bool> { .init(get: { deleteTargetID != nil }, set: { if !$0 { deleteTargetID = nil } }) }
    private func beginRename(_ scene: LightScene) { renameTargetID = scene.id; renameText = scene.name }
    private func renameScene() {
        guard let id = renameTargetID, let index = scenes.firstIndex(where: { $0.id == id }) else { return }
        let value = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { scenes[index].name = value }
        renameTargetID = nil
    }
    private func deleteScene() { scenes.removeAll { $0.id == deleteTargetID }; deleteTargetID = nil }
}

private struct LightingSceneRow: View {
    let scene: LightScene
    var body: some View {
        HStack(spacing: 14) {
            LightingCanvas(scene: scene).frame(width: 76, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(scene.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text("\(scene.layoutTitle) · \(scene.leafCount) 个区域").font(.subheadline).foregroundStyle(.white.opacity(0.56))
                Label("屏幕亮度 \(Int(scene.screenBrightness * 100))%", systemImage: "sun.max")
                    .font(.caption).foregroundStyle(LightingStyle.accent)
            }
        }.padding(.vertical, 7)
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
                Section("场景") { TextField("场景名称", text: $name) }
                Section("初始布局") {
                    ForEach(LightLayout.allCases) { item in
                        Button { layout = item } label: {
                            HStack {
                                Label(item.title, systemImage: LightingDefaults.symbol(for: item)).foregroundStyle(.primary)
                                Spacer()
                                if layout == item { Image(systemName: "checkmark.circle.fill").foregroundStyle(LightingStyle.accent) }
                            }
                        }
                    }
                }
                Section("预览") {
                    LightingCanvas(scene: LightScene(name: name, layout: layout))
                        .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 24)).listRowInsets(EdgeInsets())
                }
            }
            .navigationTitle("新建补光场景").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        create(LightScene(name: clean.isEmpty ? "未命名光场" : clean, layout: layout))
                        dismiss()
                    }
                }
            }
        }.preferredColorScheme(.dark)
    }
}

private struct LightingSceneEditorView: View {
    @Binding var scene: LightScene
    @State private var selectedID: UUID?
    @State private var history: [LightScene] = []
    @State private var showingPlayback = false
    @State private var pendingLayout: LightLayout?
    @State private var originalEditorBrightness: CGFloat?

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                InteractiveLightingCanvas(
                    root: $scene.rootNode,
                    globalSoftness: scene.globalSoftness,
                    selectedID: $selectedID,
                    beforeStructuralChange: remember
                )
                .frame(height: 330).clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay { RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.16)) }
                .padding(.top, 8)

                sceneSettings
                structureControls
                layoutPicker
                if let id = selectedID, scene.rootNode.leaf(id: id) != nil {
                    LightingZoneEditor(zone: zoneBinding(id: id), number: zoneNumber(id: id), beforeChange: remember)
                }
                Button { showingPlayback = true } label: {
                    Label("全屏发光", systemImage: "play.fill").font(.headline).frame(maxWidth: .infinity, minHeight: 56)
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .background(LightingStyle.accent, in: RoundedRectangle(cornerRadius: 18))
            }.padding(.horizontal, 16).padding(.bottom, 34)
        }
        .background(LightingStyle.background.ignoresSafeArea())
        .navigationTitle(scene.name).navigationBarTitleDisplayMode(.inline).preferredColorScheme(.dark)
        .onAppear {
            if selectedID == nil { selectedID = scene.rootNode.firstLeafID }
            if originalEditorBrightness == nil { originalEditorBrightness = UIScreen.main.brightness }
            UIScreen.main.brightness = CGFloat(scene.screenBrightness)
        }
        .onChange(of: scene.screenBrightness) { _, value in UIScreen.main.brightness = CGFloat(value) }
        .onDisappear { if let originalEditorBrightness { UIScreen.main.brightness = originalEditorBrightness } }
        .fullScreenCover(isPresented: $showingPlayback) { LightingPlaybackView(scene: scene) }
        .confirmationDialog("替换当前自由布局？", isPresented: .init(get: { pendingLayout != nil }, set: { if !$0 { pendingLayout = nil } })) {
            Button("替换布局", role: .destructive) { if let layout = pendingLayout { apply(layout) }; pendingLayout = nil }
            Button("取消", role: .cancel) { pendingLayout = nil }
        } message: { Text("会重置当前分区结构，但可使用撤销恢复。") }
    }

    private var sceneSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("场景设置", systemImage: "slider.horizontal.3").font(.headline)
            TextField("场景名称", text: $scene.name).padding(.horizontal, 13).frame(height: 46)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
            LightingValueSlider(title: "屏幕亮度", symbol: "sun.max", value: $scene.screenBrightness, range: 0.2...1, onEditingStarted: remember)
            LightingValueSlider(title: "全局柔和度", symbol: "aqi.medium", value: $scene.globalSoftness, range: 0...1, onEditingStarted: remember)
        }.lightingCard()
    }

    private var structureControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("自由分区", systemImage: "square.split.2x2").font(.headline)
                Spacer(); Text("\(scene.leafCount)/8 区").foregroundStyle(.secondary)
            }
            HStack {
                Button("左右分割", systemImage: "rectangle.split.2x1") { split(.vertical) }
                Button("上下分割", systemImage: "rectangle.split.1x2") { split(.horizontal) }
            }.buttonStyle(.bordered).tint(LightingStyle.accent).disabled(scene.leafCount >= 8)
            HStack {
                Button("合并选区", systemImage: "rectangle.compress.vertical") { merge() }
                    .disabled(selectedID.map { !scene.rootNode.canMerge(leafID: $0) } ?? true)
                Spacer()
                Button("撤销", systemImage: "arrow.uturn.backward") { undo() }.disabled(history.isEmpty)
            }.buttonStyle(.bordered)
            Text("点按选区；拖动白色分割线可调整比例。最多支持 8 个区域。")
                .font(.caption).foregroundStyle(.secondary)
        }.lightingCard()
    }

    private var layoutPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("快捷布局", systemImage: "rectangle.3.group").font(.headline)
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                ForEach(LightLayout.allCases) { layout in
                    Button {
                        if scene.leafCount > 1 { pendingLayout = layout } else { apply(layout) }
                    } label: {
                        Label(layout.title, systemImage: LightingDefaults.symbol(for: layout))
                            .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered)
                }
            }
        }.lightingCard()
    }

    private func remember() { if history.last != scene { history.append(scene) }; if history.count > 30 { history.removeFirst() } }
    private func undo() { guard let previous = history.popLast() else { return }; scene = previous; selectedID = previous.rootNode.firstLeafID }
    private func split(_ direction: LightSplitDirection) {
        guard scene.leafCount < 8, let id = selectedID else { return }
        remember(); let oldIDs = Set(scene.rootNode.leaves.map(\.id))
        scene.rootNode = scene.rootNode.splittingLeaf(id: id, direction: direction)
        selectedID = scene.rootNode.leaves.first(where: { !oldIDs.contains($0.id) })?.id ?? scene.rootNode.firstLeafID
    }
    private func merge() { guard let id = selectedID else { return }; remember(); scene.rootNode = scene.rootNode.mergingLeaf(id: id); selectedID = scene.rootNode.firstLeafID }
    private func apply(_ layout: LightLayout) { remember(); scene.rootNode = .root(for: layout); selectedID = scene.rootNode.firstLeafID }
    private func zoneBinding(id: UUID) -> Binding<LightZone> {
        .init(get: { scene.rootNode.leaf(id: id) ?? LightZone() }, set: { value in scene.rootNode = scene.rootNode.updatingLeaf(id: id) { _ in value } })
    }
    private func zoneNumber(id: UUID) -> Int { (scene.rootNode.leaves.firstIndex { $0.id == id } ?? 0) + 1 }
}

private struct LightingZoneEditor: View {
    @Binding var zone: LightZone
    let number: Int
    let beforeChange: () -> Void
    private let presets: [UInt32] = [0xFFFFFFFF, 0xFFFFE0B2, 0xFFFFB26B, 0xFFFF7043, 0xFFFF6FAD, 0xFFB36BFF, 0xFF78BFFF, 0xFF2979FF, 0xFF63E6BE]
    private var color: Binding<Color> { .init(get: { zone.colorARGB.color }, set: { beforeChange(); zone.colorARGB = $0.argb }) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("区域 \(number)").font(.headline); Spacer()
                ColorPicker("颜色", selection: color, supportsOpacity: false).labelsHidden()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(presets, id: \.self) { value in
                        Button { beforeChange(); zone.colorARGB = value } label: {
                            Circle().fill(value.color).frame(width: 32, height: 32)
                                .overlay { Circle().stroke(zone.colorARGB == value ? .white : .white.opacity(0.25), lineWidth: zone.colorARGB == value ? 3 : 1) }
                        }.buttonStyle(.plain)
                    }
                }
            }
            LightingValueSlider(title: "区域亮度", symbol: "light.max", value: $zone.intensity, range: 0...1, onEditingStarted: beforeChange)
            LightingValueSlider(title: "边界柔和度", symbol: "aqi.medium", value: $zone.softness, range: 0...1, onEditingStarted: beforeChange)
        }.lightingCard()
    }
}

private struct LightingValueSlider: View {
    let title: String; let symbol: String; @Binding var value: Double; let range: ClosedRange<Double>
    var onEditingStarted: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack { Label(title, systemImage: symbol); Spacer(); Text("\(Int(value * 100))%").monospacedDigit().foregroundStyle(LightingStyle.accent) }.font(.subheadline)
            Slider(value: $value, in: range, onEditingChanged: { if $0 { onEditingStarted() } }).tint(LightingStyle.accent)
        }
    }
}

private struct LightLeafFrame: Identifiable { let zone: LightZone; let rect: CGRect; var id: UUID { zone.id } }
private struct LightSplitFrame: Identifiable {
    let id: UUID; let direction: LightSplitDirection; let parent: CGRect; let position: CGFloat
    let firstZone: LightZone; let secondZone: LightZone
}
private struct LightGeometry { var leaves: [LightLeafFrame] = []; var splits: [LightSplitFrame] = [] }

private func lightGeometry(for node: LightNode, in rect: CGRect) -> LightGeometry {
    switch node {
    case .leaf(let zone): return LightGeometry(leaves: [.init(zone: zone, rect: rect)])
    case .split(let split):
        let ratio = CGFloat(split.ratio.clamped(to: 0.2...0.8)); let firstRect: CGRect; let secondRect: CGRect; let position: CGFloat
        if split.direction == .vertical {
            let width = rect.width * ratio; firstRect = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
            secondRect = CGRect(x: rect.minX + width, y: rect.minY, width: rect.width - width, height: rect.height); position = rect.minX + width
        } else {
            let height = rect.height * ratio; firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
            secondRect = CGRect(x: rect.minX, y: rect.minY + height, width: rect.width, height: rect.height - height); position = rect.minY + height
        }
        var result = lightGeometry(for: split.first, in: firstRect); let other = lightGeometry(for: split.second, in: secondRect)
        result.leaves += other.leaves; result.splits += other.splits
        result.splits.append(.init(
            id: split.id,
            direction: split.direction,
            parent: rect,
            position: position,
            firstZone: split.first.leaves.last ?? LightZone(),
            secondZone: split.second.leaves.first ?? LightZone()
        )); return result
    }
}

private struct LightingCanvas: View {
    let scene: LightScene
    var body: some View {
        GeometryReader { proxy in
            let geometry = lightGeometry(for: scene.rootNode, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(geometry.leaves) { leaf in
                    LightingZoneFill(zone: leaf.zone, globalSoftness: scene.globalSoftness)
                        .frame(width: leaf.rect.width, height: leaf.rect.height).position(x: leaf.rect.midX, y: leaf.rect.midY).clipped()
                }
                ForEach(geometry.splits) { split in LightingBoundaryBlend(split: split, globalSoftness: scene.globalSoftness) }
            }
        }.clipped().accessibilityLabel("\(scene.name)，\(scene.layoutTitle)，\(scene.leafCount) 个区域")
    }
}

private struct InteractiveLightingCanvas: View {
    @Binding var root: LightNode
    let globalSoftness: Double
    @Binding var selectedID: UUID?
    let beforeStructuralChange: () -> Void
    @State private var draggedSplitID: UUID?

    var body: some View {
        GeometryReader { proxy in
            let geometry = lightGeometry(for: root, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(Array(geometry.leaves.enumerated()), id: \.element.id) { index, leaf in
                    LightingZoneFill(zone: leaf.zone, globalSoftness: globalSoftness)
                        .frame(width: leaf.rect.width, height: leaf.rect.height).position(x: leaf.rect.midX, y: leaf.rect.midY).clipped()
                    Rectangle().fill(.clear).frame(width: leaf.rect.width, height: leaf.rect.height).position(x: leaf.rect.midX, y: leaf.rect.midY)
                        .overlay { if selectedID == leaf.id { Rectangle().stroke(.white, lineWidth: 3) } }
                    Text("\(index + 1)").font(.caption.bold()).padding(7).background(.black.opacity(0.45), in: Circle())
                        .position(x: leaf.rect.midX, y: leaf.rect.midY)
                }
                ForEach(geometry.splits) { split in LightingBoundaryBlend(split: split, globalSoftness: globalSoftness) }
                ForEach(geometry.splits) { split in
                    Rectangle().fill(.white.opacity(0.85))
                        .frame(width: split.direction == .vertical ? 3 : split.parent.width, height: split.direction == .vertical ? split.parent.height : 3)
                        .position(x: split.direction == .vertical ? split.position : split.parent.midX, y: split.direction == .vertical ? split.parent.midY : split.position)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if draggedSplitID == nil, let hit = nearestSplit(to: value.startLocation, in: geometry) {
                    beforeStructuralChange(); draggedSplitID = hit.id
                }
                if let id = draggedSplitID, let split = geometry.splits.first(where: { $0.id == id }) {
                    let ratio = split.direction == .vertical
                        ? (value.location.x - split.parent.minX) / split.parent.width
                        : (value.location.y - split.parent.minY) / split.parent.height
                    root = root.updatingSplitRatio(id: id, ratio: Double(ratio))
                }
            }.onEnded { value in
                if draggedSplitID == nil { selectedID = geometry.leaves.last(where: { $0.rect.contains(value.location) })?.id }
                draggedSplitID = nil
            })
        }
    }
    private func nearestSplit(to point: CGPoint, in geometry: LightGeometry) -> LightSplitFrame? {
        geometry.splits.reversed().first { split in
            split.parent.insetBy(dx: -12, dy: -12).contains(point) && abs((split.direction == .vertical ? point.x : point.y) - split.position) <= 16
        }
    }
}

private struct LightingZoneFill: View {
    let zone: LightZone; let globalSoftness: Double
    var body: some View {
        Rectangle().fill(zone.colorARGB.color.opacity(zone.intensity.clamped(to: 0...1)))
    }
}

private struct LightingBoundaryBlend: View {
    let split: LightSplitFrame
    let globalSoftness: Double
    var body: some View {
        let softness = ((split.firstZone.softness + split.secondZone.softness + globalSoftness) / 3).clamped(to: 0...1)
        let thickness = max(2, (split.direction == .vertical ? split.parent.width : split.parent.height) * CGFloat(softness) * 0.32)
        LinearGradient(
            colors: [
                split.firstZone.colorARGB.color.opacity(split.firstZone.intensity),
                split.secondZone.colorARGB.color.opacity(split.secondZone.intensity)
            ],
            startPoint: split.direction == .vertical ? .leading : .top,
            endPoint: split.direction == .vertical ? .trailing : .bottom
        )
        .frame(
            width: split.direction == .vertical ? thickness : split.parent.width,
            height: split.direction == .vertical ? split.parent.height : thickness
        )
        .position(
            x: split.direction == .vertical ? split.position : split.parent.midX,
            y: split.direction == .vertical ? split.parent.midY : split.position
        )
        .opacity(softness > 0.01 ? 1 : 0)
        .allowsHitTesting(false)
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
            LightingCanvas(scene: scene).ignoresSafeArea()
            if showingHint {
                VStack(spacing: 8) {
                    Image(systemName: "hand.tap.fill").font(.title2); Text(scene.name).font(.headline)
                    Text("长按屏幕退出发光模式").font(.subheadline).foregroundStyle(.white.opacity(0.72))
                }.padding(18).background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .contentShape(Rectangle()).onLongPressGesture(minimumDuration: 0.8) { dismiss() }
        .statusBarHidden(true).persistentSystemOverlays(.hidden)
        .onAppear(perform: captureAndApply).onDisappear(perform: restore)
        .onChange(of: scenePhase) { _, phase in phase == .active ? apply() : restore() }
        .task { try? await Task.sleep(for: .seconds(2.3)); withAnimation { showingHint = false } }
        .preferredColorScheme(.dark)
    }
    private func captureAndApply() { originalBrightness = UIScreen.main.brightness; originalIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled; apply() }
    private func apply() { UIScreen.main.brightness = CGFloat(scene.screenBrightness.clamped(to: 0.2...1)); UIApplication.shared.isIdleTimerDisabled = true }
    private func restore() { if let originalBrightness { UIScreen.main.brightness = originalBrightness }; if let originalIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = originalIdleTimerDisabled } }
}

private enum LightingDefaults {
    static func symbol(for layout: LightLayout) -> String {
        switch layout { case .single: "rectangle.fill"; case .leftRight: "rectangle.split.2x1"; case .topBottom: "rectangle.split.1x2"; case .four: "square.grid.2x2" }
    }
}
private enum LightingStyle {
    static let accent = Color(red: 1, green: 0.44, blue: 0.2)
    static let card = Color.white.opacity(0.065)
    static let background = LinearGradient(colors: [Color(red: 0.18, green: 0.055, blue: 0.075), Color(red: 0.045, green: 0.03, blue: 0.045), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
}
private extension View {
    func lightingCard() -> some View { padding(16).background(LightingStyle.card, in: RoundedRectangle(cornerRadius: 22)).overlay { RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1)) } }
}
private extension Comparable { func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) } }
