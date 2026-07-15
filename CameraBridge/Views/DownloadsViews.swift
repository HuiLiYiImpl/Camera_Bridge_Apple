import AVKit
import SwiftUI
import UIKit

struct DownloadsScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette
    @State private var filter: MediaFilter = .all
    @State private var selected: Set<UUID> = []
    @State private var preview: DownloadRecord?
    @State private var editing: [DownloadRecord] = []
    @State private var shareURLs: [URL] = []
    @State private var confirmDelete = false

    private var records: [DownloadRecord] { model.downloads.filter { filter.matches($0.kind) } }

    var body: some View {
        ZStack(alignment: .bottom) {
            palette.night.ignoresSafeArea()
            ScrollView {
                filterBar
                if !model.downloadTasks.isEmpty {
                    VStack(spacing: 10) { ForEach(model.downloadTasks) { DownloadTaskCard(task: $0) } }
                        .padding(.horizontal)
                }
                if records.isEmpty, model.downloadTasks.isEmpty {
                    ContentUnavailableView("还没有下载文件", systemImage: "arrow.down.circle", description: Text("在相机相册中选择照片或视频创建任务。"))
                        .frame(minHeight: 440)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(records) { record in
                            DownloadRecordCard(record: record, url: model.url(for: record), selected: selected.contains(record.id))
                                .onTapGesture { tap(record) }
                                .onLongPressGesture { selected.insert(record.id) }
                        }
                    }
                    .padding()
                }
                Spacer(minLength: selected.isEmpty ? 80 : 150)
            }
            if !selected.isEmpty { selectionBar }
        }
        .navigationTitle("下载")
        .toolbarBackground(palette.night, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarLeading) { if !selected.isEmpty { Button("取消") { selected.removeAll() } } } }
        .fullScreenCover(item: $preview) { DownloadPreviewScreen(record: $0) }
        .sheet(isPresented: Binding(get: { !editing.isEmpty }, set: { if !$0 { editing = [] } })) {
            DownloadEditSheet(records: editing)
        }
        .sheet(isPresented: Binding(get: { !shareURLs.isEmpty }, set: { if !$0 { shareURLs = [] } })) {
            ShareSheet(items: shareURLs)
        }
        .confirmationDialog("删除所选的 \(selected.count) 个本地文件？", isPresented: $confirmDelete) {
            Button("删除", role: .destructive) { model.deleteDownloads(ids: selected); selected.removeAll() }
            Button("取消", role: .cancel) {}
        } message: { Text("已复制到系统照片图库的独立副本不会同时删除。") }
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
        HStack(spacing: 18) {
            Text("\(selected.count) 项").font(.headline)
            Spacer()
            Button { editing = model.downloads.filter { selected.contains($0.id) } } label: { Label("处理", systemImage: "slider.horizontal.3") }
            Button { shareURLs = model.downloads.filter { selected.contains($0.id) }.map(model.url(for:)) } label: { Label("分享", systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
        }
        .labelStyle(.iconOnly).padding(16).background(.ultraThinMaterial, in: Capsule()).padding()
    }

    private func tap(_ record: DownloadRecord) {
        if selected.isEmpty { preview = record }
        else if selected.contains(record.id) { selected.remove(record.id) }
        else { selected.insert(record.id) }
    }
}

private struct DownloadTaskCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.bridgePalette) private var palette
    let task: DownloadTaskModel

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(palette.surface).frame(width: 66, height: 66)
                if let image = model.thumbnails[task.asset.handle] { Image(uiImage: image).resizable().scaledToFill().frame(width: 66, height: 66).clipShape(RoundedRectangle(cornerRadius: 12)) }
                else { Image(systemName: task.asset.kind == .video ? "video" : "photo") }
                Circle().stroke(palette.text.opacity(0.18), lineWidth: 4).frame(width: 48, height: 48)
                Circle().trim(from: 0, to: task.progress).stroke(palette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(task.asset.name).font(.subheadline.bold()).lineLimit(1)
                if task.status == .failed { Text(task.errorMessage ?? "下载失败").font(.caption).foregroundStyle(.red).lineLimit(2) }
                else {
                    Text("\(task.downloadedBytes.byteCountText) / \(task.totalBytes.byteCountText)").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(task.bytesPerSecond.map { "\($0.byteCountText)/s" } ?? "等待中")
                        Text(task.remainingSeconds.map(etaText) ?? "计算中")
                    }.font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if task.status == .failed {
                Button { model.retryDownload(id: task.id) } label: { Image(systemName: "arrow.clockwise") }
            } else {
                Button { model.cancelDownload(id: task.id) } label: { Image(systemName: "xmark.circle") }
            }
        }
        .foregroundStyle(palette.text).bridgeCard()
    }

    private func etaText(_ seconds: Int) -> String {
        seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60) : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct DownloadRecordCard: View {
    @Environment(\.bridgePalette) private var palette
    let record: DownloadRecord
    let url: URL
    let selected: Bool
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(palette.surface).aspectRatio(4 / 3, contentMode: .fit)
                if let image { Image(uiImage: image).resizable().scaledToFill().clipped() }
                else { Image(systemName: record.kind == .video ? "play.rectangle.fill" : record.kind == .rawImage ? "camera.raw" : "photo.fill").font(.largeTitle).foregroundStyle(palette.accent) }
                if selected { Color.black.opacity(0.35); Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(palette.accent) }
                if record.edited { Text("EDIT").font(.caption2.bold()).padding(5).background(.black.opacity(0.7), in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(7) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(record.name).font(.subheadline.bold()).lineLimit(1)
            HStack { Text(record.size.byteCountText); Spacer(); Text(record.completedAt.bridgeDateText) }.font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(palette.text).bridgeCard()
        .task {
            guard record.kind == .image || record.kind == .rawImage else { return }
            image = UIImage(contentsOfFile: url.path)
        }
    }
}

struct DownloadPreviewScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: DownloadRecord
    @State private var player: AVPlayer?
    @State private var image: UIImage?
    @State private var showingShare = false
    @State private var showingEdit = false
    @State private var rotation = 0

    var body: some View {
        let url = model.url(for: record)
        ZStack {
            Color.black.ignoresSafeArea()
            if record.kind == .video, let player { VideoPlayer(player: player).ignoresSafeArea().onAppear { player.play() }.onDisappear { player.pause() } }
            else if let image { ZoomableImage(image: image, rotation: rotation) }
            else { ContentUnavailableView("无法预览", systemImage: "doc.questionmark").foregroundStyle(.white) }
            VStack {
                HStack {
                    Button(action: dismiss.callAsFunction) { Image(systemName: "xmark").frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle()) }
                    Spacer(); Text(record.name).lineLimit(1); Spacer()
                    Button { showingShare = true } label: { Image(systemName: "square.and.arrow.up").frame(width: 42, height: 42).background(.ultraThinMaterial, in: Circle()) }
                }
                Spacer()
                HStack {
                    if record.kind != .video { Button { rotation = (rotation + 90) % 360 } label: { Label("旋转", systemImage: "rotate.right") } }
                    Button { showingEdit = true } label: { Label("LUT / 水印", systemImage: "slider.horizontal.3") }
                }
                .buttonStyle(.bordered).padding().background(.ultraThinMaterial, in: Capsule())
            }
            .padding().foregroundStyle(.white)
        }
        .task {
            if record.kind == .video { player = AVPlayer(url: url) }
            else { image = UIImage(contentsOfFile: url.path) }
        }
        .sheet(isPresented: $showingShare) { ShareSheet(items: [url]) }
        .sheet(isPresented: $showingEdit) { DownloadEditSheet(records: [record]) }
    }
}

struct DownloadEditSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let records: [DownloadRecord]
    @State private var lutID: UUID?
    @State private var watermarkID: UUID?
    @State private var intensity = 1.0
    @State private var rotation = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("处理 \(records.count) 个文件") {
                    Picker("LUT", selection: $lutID) {
                        Text("无").tag(UUID?.none)
                        ForEach(model.luts) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if lutID != nil { Slider(value: $intensity, in: 0 ... 1) { Text("LUT 强度") }; Text("强度 \(Int(intensity * 100))%") }
                    Picker("水印", selection: $watermarkID) {
                        Text("无").tag(UUID?.none)
                        ForEach(model.watermarks) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("旋转", selection: $rotation) {
                        Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                    }
                }
                Section {
                    Button {
                        model.exportBatch(
                            records: records,
                            lutEntry: model.luts.first { $0.id == lutID }, intensity: intensity,
                            watermark: model.watermarks.first { $0.id == watermarkID }, rotation: rotation
                        )
                        dismiss()
                    } label: { Label("导出处理结果", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                    .disabled(model.exportProgress != nil || (lutID == nil && watermarkID == nil && rotation == 0))
                }
            }
            .navigationTitle("LUT 与水印").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", action: dismiss.callAsFunction) } }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
