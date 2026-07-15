import SwiftUI
import UIKit

struct GalleryScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette
    @State private var filter: MediaFilter = .all
    @State private var selected: Set<UInt32> = []
    @State private var preview: PhotoAsset?

    private let columns = [GridItem(.adaptive(minimum: 105), spacing: 3)]
    private var filtered: [PhotoAsset] { model.photos.filter { filter.matches($0.kind) } }

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.night.ignoresSafeArea()
            if model.session == nil {
                ContentUnavailableView("尚未连接相机", systemImage: "camera.badge.ellipsis", description: Text("请先在相机页建立 Wi-Fi 或 USB 连接。"))
            } else if model.photos.isEmpty, !model.isBusy {
                ContentUnavailableView("相机中没有媒体", systemImage: "photo.on.rectangle.angled", description: Text("拍摄后点击右上角重新读取。"))
            } else {
                ScrollView {
                    filterBar
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(filtered) { asset in
                            PhotoAssetCell(asset: asset, image: model.thumbnails[asset.handle], selected: selected.contains(asset.handle))
                                .onAppear {
                                    model.loadThumbnail(for: asset)
                                    if filter == .all, asset.id == filtered.last?.id { model.loadMorePhotos() }
                                }
                                .onTapGesture { tap(asset) }
                                .onLongPressGesture { selected.insert(asset.handle) }
                        }
                    }
                    if model.hasMorePhotos {
                        Button(action: model.loadMorePhotos) {
                            HStack { if model.isBusy { ProgressView() }; Text("加载更多") }
                                .frame(maxWidth: .infinity).padding()
                        }
                    }
                    Spacer(minLength: selected.isEmpty ? 80 : 150)
                }
            }
            if !selected.isEmpty { selectionBar }
        }
        .navigationTitle("相机相册")
        .toolbarBackground(palette.night, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if !selected.isEmpty { Button("取消") { selected.removeAll() } }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.disabled(model.isBusy || model.session == nil)
            }
        }
        .fullScreenCover(item: $preview) { asset in PhotoPreviewScreen(asset: asset) }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MediaFilter.allCases) { item in
                    Button(item.title) { filter = item; selected.removeAll() }
                        .font(.subheadline.weight(item == filter ? .bold : .medium))
                        .foregroundStyle(item == filter ? palette.night : palette.text)
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .background(item == filter ? palette.accent : palette.elevated, in: Capsule())
                }
            }
            .padding(.horizontal).padding(.vertical, 10)
        }
    }

    private var selectionBar: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("已选择 \(selected.count) 项").font(.headline)
                Text("创建原片下载任务").font(.caption).foregroundStyle(palette.text.opacity(0.55))
            }
            Spacer()
            Button {
                model.enqueue(model.photos.filter { selected.contains($0.handle) })
                selected.removeAll()
            } label: { Label("下载", systemImage: "arrow.down.circle.fill").padding(.horizontal, 14).padding(.vertical, 10) }
                .background(palette.accent, in: Capsule()).foregroundStyle(palette.night)
        }
        .padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24)).padding()
    }

    private func tap(_ asset: PhotoAsset) {
        if selected.isEmpty { preview = asset }
        else if selected.contains(asset.handle) { selected.remove(asset.handle) }
        else { selected.insert(asset.handle) }
    }
}

private struct PhotoAssetCell: View {
    @Environment(\.bridgePalette) private var palette
    let asset: PhotoAsset
    let image: UIImage?
    let selected: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(palette.elevated).aspectRatio(1, contentMode: .fit)
            if let image { Image(uiImage: image).resizable().scaledToFill().clipped() }
            else { ProgressView().tint(palette.accent) }
            VStack {
                HStack {
                    Text(asset.typeLabel).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 3).background(.black.opacity(0.65), in: Capsule())
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent).background(.black, in: Circle()) }
                }
                Spacer()
                HStack {
                    if asset.kind == .video { Image(systemName: "play.fill") }
                    Text(asset.name).lineLimit(1)
                    Spacer()
                }
                .font(.caption2).padding(6).background(LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
            }
            .padding(5).foregroundStyle(.white)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? palette.accent : .clear, lineWidth: 3))
    }
}

struct PhotoPreviewScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.bridgePalette) private var palette
    let asset: PhotoAsset
    @State private var original: UIImage?
    @State private var preview: UIImage?
    @State private var loading = false
    @State private var rotation = 0
    @State private var selectedLUT: UUID?
    @State private var selectedWatermark: UUID?
    @State private var intensity = 1.0
    @State private var showingEditor = false
    @State private var renderTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if asset.kind == .video {
                VStack(spacing: 18) {
                    Image(systemName: "video.fill").font(.system(size: 60)).foregroundStyle(palette.accent)
                    Text("视频需先下载后播放和应用 LUT").foregroundStyle(.white.opacity(0.7))
                    Button("创建下载任务") { model.enqueue([asset]); dismiss() }.buttonStyle(.borderedProminent)
                }
            } else if let image = preview ?? original ?? model.thumbnails[asset.handle] {
                ZoomableImage(image: image, rotation: rotation)
            } else {
                ProgressView("正在加载预览").tint(palette.accent).foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Button(action: dismiss.callAsFunction) { Image(systemName: "xmark").frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle()) }
                    Spacer()
                    Text(asset.name).font(.subheadline.bold()).lineLimit(1)
                    Spacer()
                    Button { rotation = (rotation + 270) % 360 } label: { Image(systemName: "rotate.left").frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle()) }
                }
                .foregroundStyle(.white).padding()
                Spacer()
                if asset.kind != .video {
                    HStack(spacing: 12) {
                        Button {
                            model.enqueue([asset]); model.notice = "已创建下载任务"
                        } label: { Label("原片", systemImage: "arrow.down.circle") }
                            .buttonStyle(.bordered)
                        Button { showingEditor.toggle() } label: { Label("编辑", systemImage: "slider.horizontal.3") }
                            .buttonStyle(.bordered)
                        Button {
                            guard let image = original else { return }
                            model.exportRemoteImage(
                                asset: asset, image: image,
                                lutEntry: model.luts.first { $0.id == selectedLUT }, intensity: intensity,
                                watermark: model.watermarks.first { $0.id == selectedWatermark }, rotation: rotation
                            )
                        } label: { Label("导出", systemImage: "square.and.arrow.down") }
                            .buttonStyle(.borderedProminent).disabled(original == nil || model.exportProgress != nil)
                    }
                    .padding().background(.ultraThinMaterial, in: Capsule()).foregroundStyle(.white)
                }
            }
            if showingEditor { editorDrawer.transition(.move(edge: .trailing)) }
            if loading { Color.black.opacity(0.3).ignoresSafeArea(); ProgressView().controlSize(.large).tint(palette.accent) }
            if let progress = model.exportProgress {
                VStack { ProgressView(value: progress); Text("正在导出 \(Int(progress * 100))%") }
                    .padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white)
            }
        }
        .task { await loadOriginal() }
        .onChange(of: selectedLUT) { _, _ in renderLUTPreview() }
        .onChange(of: intensity) { _, _ in renderLUTPreview() }
    }

    private var editorDrawer: some View {
        HStack {
            Spacer()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text("照片编辑").font(.headline); Spacer(); Button { showingEditor = false } label: { Image(systemName: "xmark") } }
                    Text("LUT").font(.caption).foregroundStyle(.secondary)
                    Picker("LUT", selection: $selectedLUT) {
                        Text("无").tag(UUID?.none)
                        ForEach(model.luts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if selectedLUT != nil {
                        Text("强度 \(Int(intensity * 100))%").font(.caption)
                        Slider(value: $intensity, in: 0 ... 1)
                    }
                    Divider()
                    Text("水印").font(.caption).foregroundStyle(.secondary)
                    Picker("水印", selection: $selectedWatermark) {
                        Text("无").tag(UUID?.none)
                        ForEach(model.watermarks) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Button("还原效果") { selectedLUT = nil; selectedWatermark = nil; intensity = 1; rotation = 0; preview = original }
                }
                .padding()
            }
            .frame(width: min(310, UIScreen.main.bounds.width * 0.78))
            .background(.ultraThinMaterial)
        }
        .ignoresSafeArea()
    }

    private func loadOriginal() async {
        guard original == nil else { return }
        loading = true
        original = await model.loadOriginalImage(for: asset)
        preview = original
        loading = false
    }

    private func renderLUTPreview() {
        renderTask?.cancel()
        guard let original else { return }
        guard let entry = model.luts.first(where: { $0.id == selectedLUT }) else { preview = original; return }
        do {
            let lut = try model.lut(for: entry)
            let amount = intensity
            renderTask = Task {
                let rendered = try? await Task.detached { try LUTProcessor.shared.apply(lut, to: original, intensity: amount) }.value
                if !Task.isCancelled { preview = rendered ?? original }
            }
        } catch { model.alertMessage = error.localizedDescription }
    }
}

struct ZoomableImage: View {
    let image: UIImage
    let rotation: Int
    @State private var scale = 1.0
    @State private var lastScale = 1.0
    @State private var offset = CGSize.zero
    @State private var lastOffset = CGSize.zero

    var body: some View {
        Image(uiImage: image).resizable().scaledToFit()
            .rotationEffect(.degrees(Double(rotation)))
            .scaleEffect(scale).offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = min(max(lastScale * $0, 1), 12) }
                    .onEnded { _ in lastScale = scale; if scale == 1 { offset = .zero; lastOffset = .zero } }
            )
            .simultaneousGesture(
                DragGesture().onChanged { value in
                    guard scale > 1 else { return }
                    offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                }.onEnded { _ in lastOffset = offset }
            )
            .onTapGesture(count: 2) {
                withAnimation { scale = scale > 1 ? 1 : 3; lastScale = scale; if scale == 1 { offset = .zero; lastOffset = .zero } }
            }
    }
}
