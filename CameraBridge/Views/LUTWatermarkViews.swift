import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct LUTLibraryScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette
    @State private var search = ""
    @State private var category: LUTCategory?
    @State private var showingImporter = false
    @State private var showingWatermarks = false
    @State private var editing: LUTEntry?
    @State private var photoItem: PhotosPickerItem?
    @State private var sampleImage: UIImage?
    @State private var renderedSample: UIImage?
    @State private var selectedLUT: UUID?
    @State private var intensity = 1.0

    private var filtered: [LUTEntry] {
        model.luts.filter { entry in
            (category == nil || entry.category == category) && (search.isEmpty || entry.name.localizedCaseInsensitiveContains(search))
        }.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite }
            return (lhs.lastUsedAt ?? lhs.importedAt) > (rhs.lastUsedAt ?? rhs.importedAt)
        }
    }

    var body: some View {
        libraryContent
            .navigationTitle("LUT 库")
            .searchable(text: $search, prompt: "搜索 LUT")
            .toolbarBackground(palette.night, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingWatermarks = true } label: { Image(systemName: "textformat") }
                    Button { showingImporter = true } label: { Image(systemName: "plus") }
                }
            }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: importTypes,
                allowsMultipleSelection: true,
                onCompletion: handleImport
            )
            .sheet(isPresented: $showingWatermarks) { NavigationStack { WatermarkLibraryScreen() } }
            .sheet(item: $editing) { LUTEditSheet(entry: $0) }
            .onChange(of: photoItem) { _, item in loadSample(from: item) }
            .onChange(of: intensity) { _, _ in renderSample() }
    }

    private var libraryContent: some View {
        ZStack {
            palette.night.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 14) {
                    previewCard
                    categoryBar
                    if filtered.isEmpty {
                        ContentUnavailableView("没有 LUT", systemImage: "camera.filters", description: Text("导入 .cube、Hald PNG 或 Adobe XMP。"))
                            .frame(minHeight: 260)
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(filtered) { entry in
                                LUTRow(
                                    entry: entry,
                                    selected: selectedLUT == entry.id,
                                    select: { selectedLUT = entry.id; renderSample() },
                                    edit: { editing = entry }
                                )
                            }
                        }
                    }
                }
                .padding().padding(.bottom, 80)
            }
        }
    }

    private var importTypes: [UTType] {
        [UTType(filenameExtension: "cube")!, .png, UTType(filenameExtension: "xmp")!]
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task { for url in urls { await model.importLUT(from: url) } }
        case .failure(let error):
            model.alertMessage = error.localizedDescription
        }
    }

    private func loadSample(from item: PhotosPickerItem?) {
        Task {
            if let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                sampleImage = image
                renderSample()
            }
        }
    }

    private var previewCard: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(palette.surface).aspectRatio(16 / 10, contentMode: .fit)
                if let image = renderedSample ?? sampleImage { Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 16)) }
                else {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        VStack(spacing: 8) { Image(systemName: "photo.badge.plus").font(.largeTitle); Text("选择照片预览 LUT") }
                            .foregroundStyle(palette.text.opacity(0.62))
                    }
                }
            }
            if selectedLUT != nil {
                HStack { Text("强度"); Slider(value: $intensity, in: 0 ... 1); Text("\(Int(intensity * 100))%").monospacedDigit() }.font(.caption)
            }
        }
        .foregroundStyle(palette.text).bridgeCard()
    }

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                chip("全部", selected: category == nil) { category = nil }
                ForEach(LUTCategory.allCases) { value in chip(value.title, selected: category == value) { category = value } }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action).font(.caption.bold()).padding(.horizontal, 13).padding(.vertical, 8)
            .foregroundStyle(selected ? palette.night : palette.text)
            .background(selected ? palette.accent : palette.elevated, in: Capsule())
    }

    private func renderSample() {
        guard let sampleImage, let entry = model.luts.first(where: { $0.id == selectedLUT }) else { renderedSample = sampleImage; return }
        do {
            let lut = try model.lut(for: entry)
            let amount = intensity
            Task {
                renderedSample = (try? await Task.detached { try LUTProcessor.shared.apply(lut, to: sampleImage, intensity: amount) }.value) ?? sampleImage
            }
        } catch { model.alertMessage = error.localizedDescription }
    }
}

private struct LUTRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette
    let entry: LUTEntry
    let selected: Bool
    let select: () -> Void
    let edit: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 13) {
                ZStack { RoundedRectangle(cornerRadius: 12).fill(palette.accent.opacity(0.14)).frame(width: 52, height: 52); Image(systemName: "camera.filters").foregroundStyle(palette.accent) }
                VStack(alignment: .leading) {
                    Text(entry.name).font(.headline).lineLimit(1)
                    Text("\(entry.format) · \(entry.dimension)³ · \(entry.category.title)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    var changed = entry; changed.favorite.toggle(); model.updateLUT(changed)
                } label: { Image(systemName: entry.favorite ? "star.fill" : "star") }.buttonStyle(.plain)
                Menu {
                    Button("编辑", action: edit)
                    Button("删除", role: .destructive) { model.removeLUT(entry) }
                } label: { Image(systemName: "ellipsis") }
            }
            .foregroundStyle(palette.text)
        }
        .buttonStyle(.plain).bridgeCard()
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? palette.accent : .clear, lineWidth: 2))
    }
}

private struct LUTEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LUTEntry
    init(entry: LUTEntry) { _draft = State(initialValue: entry) }
    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $draft.name)
                Picker("分类", selection: $draft.category) { ForEach(LUTCategory.allCases) { Text($0.title).tag($0) } }
                Toggle("收藏", isOn: $draft.favorite)
            }
            .navigationTitle("编辑 LUT").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: dismiss.callAsFunction) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { model.updateLUT(draft); dismiss() }.disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
        }
    }
}

struct WatermarkLibraryScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette
    @State private var editing: WatermarkPreset?

    var body: some View {
        List {
            Section {
                ForEach(model.watermarks) { preset in
                    Button { editing = preset } label: {
                        HStack {
                            Image(systemName: preset.layout == .whiteBorder ? "square" : "text.below.photo").foregroundStyle(palette.accent)
                            VStack(alignment: .leading) { Text(preset.name); Text(preset.layout.title).font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Image(systemName: "chevron.right")
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { model.removeWatermark(preset) } }
                }
            } footer: { Text("品牌 Logo 仅用于用户自己的照片；发布前请确认相应商标使用要求。") }
        }
        .scrollContentBackground(.hidden).background(palette.night)
        .navigationTitle("水印模板")
        .toolbar {
            Button {
                var preset = WatermarkPreset.defaults[0]; preset.id = UUID(); preset.name = "新水印"; editing = preset
            } label: { Image(systemName: "plus") }
        }
        .sheet(item: $editing) { WatermarkEditorSheet(preset: $0) }
    }
}

private struct WatermarkEditorSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WatermarkPreset
    @State private var photoItem: PhotosPickerItem?
    @State private var sampleImage: UIImage?
    @State private var renderedPreview: UIImage?
    @State private var renderTask: Task<Void, Never>?
    @State private var showingLogoImporter = false
    init(preset: WatermarkPreset) { _draft = State(initialValue: preset) }

    var body: some View {
        NavigationStack {
            Form {
                Section("实时预览") {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.12)).aspectRatio(16 / 10, contentMode: .fit)
                        if let image = renderedPreview ?? sampleImage {
                            Image(uiImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            PhotosPicker(selection: $photoItem, matching: .images) {
                                Label("选择照片预览模板", systemImage: "photo.badge.plus")
                            }
                        }
                    }
                    if sampleImage != nil {
                        PhotosPicker(selection: $photoItem, matching: .images) { Label("更换预览照片", systemImage: "photo") }
                    }
                }
                Section("模板") {
                    TextField("名称", text: $draft.name)
                    Picker("布局", selection: $draft.layout) { ForEach(WatermarkLayout.allCases) { Text($0.title).tag($0) } }
                }
                Section("信息字段") {
                    ForEach(WatermarkField.allCases) { field in
                        Toggle(field.title, isOn: Binding(
                            get: { draft.fields.contains(field) },
                            set: { enabled in if enabled { draft.fields.insert(field) } else { draft.fields.remove(field) } }
                        ))
                    }
                }
                Section("样式") {
                    ColorPicker("文字颜色", selection: Binding(get: { draft.textColor.color }, set: { draft.textColor = $0.argb }), supportsOpacity: true)
                    ColorPicker("背景颜色", selection: Binding(get: { draft.backgroundColor.color }, set: { draft.backgroundColor = $0.argb }), supportsOpacity: true)
                    Stepper("字号 \(Int(draft.fontSize))", value: $draft.fontSize, in: 16 ... 80)
                    Stepper("边距 \(Int(draft.margin))", value: $draft.margin, in: 0 ... 100)
                    Toggle("白色边框", isOn: $draft.frameEnabled)
                    if draft.frameEnabled { Stepper("边框厚度 \(Int(draft.frameThickness))", value: $draft.frameThickness, in: 4 ... 100) }
                    Toggle("显示 Logo", isOn: $draft.logoEnabled)
                    if draft.logoEnabled {
                        Toggle("自动使用品牌 Logo", isOn: $draft.useBrandLogo)
                        Slider(value: $draft.logoScale, in: 0.4 ... 2) { Text("Logo 大小") }
                        Slider(value: $draft.logoAlpha, in: 0.1 ... 1) { Text("Logo 透明度") }
                        Button { showingLogoImporter = true } label: { Label("导入自定义 Logo", systemImage: "photo.badge.plus") }
                        if draft.logoName != nil {
                            Button("移除自定义 Logo", role: .destructive) { draft.logoName = nil }
                        }
                    }
                    Slider(value: $draft.backgroundAlpha, in: 0 ... 1) { Text("背景透明度") }
                    Slider(value: $draft.quality, in: 0.5 ... 1) { Text("输出质量") }
                }
                Section("文字") {
                    TextField("自定义文字", text: $draft.customText)
                    TextField("版权文字", text: $draft.copyrightText)
                }
            }
            .navigationTitle("水印编辑").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", action: dismiss.callAsFunction) }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { model.saveWatermark(draft); dismiss() }.disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }
            .fileImporter(isPresented: $showingLogoImporter, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { importLogo(from: url) }
                else if case .failure(let error) = result { model.alertMessage = error.localizedDescription }
            }
            .onChange(of: photoItem) { _, item in loadPreviewPhoto(from: item) }
            .onChange(of: draft) { _, _ in renderPreview() }
            .onDisappear { renderTask?.cancel() }
        }
    }

    private func loadPreviewPhoto(from item: PhotosPickerItem?) {
        Task {
            guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
            sampleImage = image
            renderPreview()
        }
    }

    private func renderPreview() {
        renderTask?.cancel()
        guard let sampleImage else { renderedPreview = nil; return }
        let preset = draft
        let metadata = PhotoMetadata(
            cameraBrand: "Nikon", cameraModel: "Z f", lensModel: "NIKKOR Z 40mm f/2",
            iso: 100, shutterSpeed: "1/250s", aperture: "f/2.8", focalLength: "40mm",
            equivalentFocalLength: "40mm", capturedAt: .now, customText: preset.customText,
            copyrightText: preset.copyrightText
        )
        renderTask = Task {
            let rendered = try? await Task.detached {
                try WatermarkRenderer.shared.render(image: sampleImage, metadata: metadata, preset: preset)
            }.value
            if !Task.isCancelled { renderedPreview = rendered ?? sampleImage }
        }
    }

    private func importLogo(from source: URL) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("WatermarkLogos", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let destination = base.appendingPathComponent("\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: source, to: destination)
            draft.logoName = destination.path
            draft.useBrandLogo = false
            draft.logoEnabled = true
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }
}
