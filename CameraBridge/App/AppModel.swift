import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var config: CameraConfig {
        didSet {
            store.save(config: config)
            updateIdleTimerPolicy()
        }
    }
    @Published private(set) var workflow: Workflow = .waiting
    @Published private(set) var session: CameraSession?
    @Published private(set) var photos: [PhotoAsset] = []
    @Published private(set) var hasMorePhotos = false
    @Published private(set) var thumbnails: [UInt32: UIImage] = [:]
    @Published private(set) var downloadTasks: [DownloadTaskModel] = []
    @Published private(set) var downloads: [DownloadRecord] { didSet { store.save(downloads: downloads) } }
    @Published private(set) var luts: [LUTEntry] { didSet { store.save(luts: luts) } }
    @Published private(set) var watermarks: [WatermarkPreset] { didSet { store.save(watermarks: watermarks) } }
    @Published var lightScenes: [LightScene] { didSet { store.save(lightScenes: lightScenes) } }
    @Published var notice: String?
    @Published var alertMessage: String?
    @Published var exportProgress: Double? { didSet { updateIdleTimerPolicy() } }
    @Published private(set) var remoteBatchStatus: String?

    let usbClient: ImageCaptureCameraClient
    private let store: AppStore
    private let diagnostics = DiagnosticsLogger()
    private let notifications = NotificationService.shared
    private var wifiClient: PTPIPClient?
    private var downloadWorker: Task<Void, Never>?
    private var downloadTokens: [String: DownloadCancellationToken] = [:]
    private var lutCache: [UUID: CubeLUT] = [:]
    private var lutCacheOrder: [UUID] = []
    private var thumbnailLoader: Task<Void, Never>?
    private var remoteBatchTask: Task<Void, Never>?
    private var remoteBatchDownloadToken: DownloadCancellationToken?
    private var remoteBatchAssetHandle: UInt32?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var notificationObserver: NSObjectProtocol?
    private var lastNotifiedPercentage: [String: Int] = [:]
    private let firstPageSize = 30

    init(store: AppStore = AppStore()) {
        self.store = store
        config = store.loadConfig()
        let saved = store.loadDownloads()
        downloads = store.pruneMissingDownloads(saved)
        luts = store.loadLUTs()
        watermarks = store.loadWatermarks()
        lightScenes = store.loadLightScenes()
        usbClient = ImageCaptureCameraClient()
        if downloads.count != saved.count { store.save(downloads: downloads) }
        notificationObserver = NotificationCenter.default.addObserver(
            forName: NotificationService.retryRequestedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let taskID = NotificationService.taskID(from: notification.userInfo ?? [:]) else { return }
            Task { @MainActor [weak self] in self?.retryDownload(id: taskID) }
        }
        Task { await diagnostics.log("APP_STARTED", phase: "APP_READY", message: "Camera Bridge started") }
    }

    var isBusy: Bool { workflow.busy }
    var isConnected: Bool { session != nil }
    var activeDownloadCount: Int { downloadTasks.filter { $0.status != .failed }.count }

    func connectWiFi() {
        guard !workflow.busy else { return }
        workflow = .connecting
        notice = "正在连接 \(config.host):\(config.port)"
        Task {
            await diagnostics.log("WIFI_CONNECT_STARTED", phase: "PTP_INIT", transport: .wifi, message: notice ?? "")
            do {
                let client = try PTPIPClient(host: config.host, port: config.port)
                let connected = try await client.connect()
                wifiClient = client
                session = connected
                config.lastCameraName = connected.name
                config.lastTransport = .wifi
                workflow = .connected
                notice = "\(connected.name) · Wi-Fi 已连接"
                await diagnostics.log("WIFI_CONNECT_SUCCEEDED", phase: "PTP_SESSION", transport: .wifi, message: connected.name)
                await loadPhotos(reset: true)
            } catch {
                await fail(error, event: "WIFI_CONNECT_FAILED", phase: "PTP_INIT", transport: .wifi)
            }
        }
    }

    func startUSBDiscovery() {
        Task {
            do {
                try await usbClient.startDiscovery()
                notice = usbClient.discoveredCameras.isEmpty ? "请连接相机并将 USB 模式设为 PTP/MTP" : "检测到 \(usbClient.discoveredCameras.count) 台相机"
                await diagnostics.log("USB_DISCOVERY_STARTED", phase: "USB_DISCOVERY", transport: .usb)
            } catch {
                await fail(error, event: "USB_DISCOVERY_FAILED", phase: "USB_AUTH", transport: .usb)
            }
        }
    }

    func connectUSB(_ descriptor: ImageCaptureCameraDescriptor? = nil) {
        guard !workflow.busy else { return }
        workflow = .connecting
        Task {
            do {
                let connected = try await usbClient.connect(to: descriptor)
                session = connected
                config.lastCameraName = connected.name
                config.lastTransport = .usb
                workflow = .connected
                notice = "\(connected.name) · USB 已连接"
                await diagnostics.log("USB_CONNECT_SUCCEEDED", phase: "USB_SESSION", transport: .usb, message: connected.name)
                await loadPhotos(reset: true)
            } catch {
                await fail(error, event: "USB_CONNECT_FAILED", phase: "USB_SESSION", transport: .usb)
            }
        }
    }

    func disconnect() {
        guard let transport = session?.transport else { return }
        downloadTokens.values.forEach { $0.cancel() }
        Task {
            if transport == .wifi { await wifiClient?.disconnect(); wifiClient = nil }
            else { await usbClient.disconnect() }
            session = nil
            photos.removeAll()
            thumbnails.removeAll()
            hasMorePhotos = false
            workflow = .waiting
            notice = "已断开相机连接"
            await diagnostics.log("CAMERA_DISCONNECTED", phase: "DISCONNECT", transport: transport)
        }
    }

    func refresh() {
        Task { await loadPhotos(reset: true) }
    }

    func loadMorePhotos() {
        guard hasMorePhotos, !workflow.busy else { return }
        Task { await loadPhotos(reset: false) }
    }

    func loadPhotos(reset: Bool) async {
        guard let session else { return }
        workflow = .loading
        notice = reset ? "正在读取相机相册" : "正在加载更多"
        do {
            let offset = reset ? 0 : photos.count
            let limit = reset ? firstPageSize : 15
            let page: [PhotoAsset]
            let hasMore: Bool
            if session.transport == .wifi {
                guard let wifiClient else { throw PTPError.disconnected }
                if reset { await wifiClient.refreshAssets() }
                let result = try await wifiClient.assets(offset: offset, limit: limit)
                page = result.items
                hasMore = result.hasMore
            } else {
                if reset { usbClient.refreshAssets() }
                page = try usbClient.assets(offset: offset, limit: limit)
                hasMore = usbClient.hasMoreAssets(after: offset + page.count)
            }
            photos = reset ? page : photos + page
            hasMorePhotos = hasMore
            workflow = .connected
            notice = hasMore ? "已读取 \(photos.count) 个文件" : "已全部读取 · \(photos.count) 个文件"
            await diagnostics.log("ASSET_LIST_SUCCEEDED", phase: "ASSET_LIST", transport: session.transport, message: "count=\(page.count) total=\(photos.count)")
            loadMissingThumbnails(page)
        } catch {
            await fail(error, event: "ASSET_LIST_FAILED", phase: "ASSET_LIST", transport: session.transport)
        }
    }

    func loadThumbnail(for asset: PhotoAsset) {
        guard thumbnails[asset.handle] == nil else { return }
        loadMissingThumbnails([asset])
    }

    private func loadMissingThumbnails(_ assets: [PhotoAsset]) {
        let pending = assets.filter { thumbnails[$0.handle] == nil }
        guard !pending.isEmpty, thumbnailLoader == nil else { return }
        thumbnailLoader = Task {
            defer { thumbnailLoader = nil }
            for asset in pending where !Task.isCancelled {
                do {
                    let data: Data?
                    if session?.transport == .wifi { data = try await wifiClient?.thumbnail(for: asset) }
                    else { data = try await usbClient.thumbnail(for: asset) }
                    if let data, let image = UIImage(data: data) { thumbnails[asset.handle] = image }
                } catch {
                    await diagnostics.log("THUMBNAIL_FAILED", phase: "THUMBNAIL", level: "WARN", transport: session?.transport, message: asset.name, error: error)
                }
            }
        }
    }

    func loadOriginalImage(for asset: PhotoAsset) async -> UIImage? {
        guard asset.kind != .video else { return nil }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString)-\(asset.name)")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let token = DownloadCancellationToken()
            if session?.transport == .wifi {
                guard let wifiClient else { throw PTPError.disconnected }
                try await wifiClient.download(asset, to: temp, cancellation: token) { _, _ in }
            } else {
                _ = try await usbClient.download(asset, to: temp)
            }
            return UIImage(contentsOfFile: temp.path)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func enqueue(_ assets: [PhotoAsset]) -> (created: Int, existing: Int) {
        guard let session else { return (0, 0) }
        var created = 0
        var existing = 0
        let known = Set(downloadTasks.map(\.id))
        var added: [DownloadTaskModel] = []
        var mutableKnown = known
        for asset in assets {
            let task = DownloadTaskModel(asset: asset, sessionName: session.name)
            if mutableKnown.contains(task.id) { existing += 1 }
            else { mutableKnown.insert(task.id); added.append(task); created += 1 }
        }
        downloadTasks.append(contentsOf: added)
        if created > 0 {
            notice = "已创建 \(created) 个下载任务"
            Task { _ = try? await notifications.requestAuthorization() }
            startDownloadWorker()
        }
        if existing > 0 { alertMessage = "\(existing) 个文件已有下载任务" }
        return (created, existing)
    }

    func cancelDownload(id: String) {
        guard let index = downloadTasks.firstIndex(where: { $0.id == id }) else { return }
        switch downloadTasks[index].status {
        case .queued:
            notifications.removeDownloadNotification(taskID: id)
            lastNotifiedPercentage[id] = nil
            downloadTasks.remove(at: index)
        case .downloading, .cancelling:
            downloadTasks[index].status = .cancelling
            downloadTokens[id]?.cancel()
            if session?.transport == .usb { usbClient.cancelDownload(for: downloadTasks[index].asset.handle) }
        case .failed:
            notifications.removeDownloadNotification(taskID: id)
            lastNotifiedPercentage[id] = nil
            downloadTasks.remove(at: index)
        }
    }

    func retryDownload(id: String) {
        guard let index = downloadTasks.firstIndex(where: { $0.id == id }), downloadTasks[index].status == .failed else { return }
        downloadTasks[index].status = .queued
        downloadTasks[index].downloadedBytes = 0
        downloadTasks[index].bytesPerSecond = nil
        downloadTasks[index].remainingSeconds = nil
        downloadTasks[index].errorMessage = nil
        notifications.removeDownloadNotification(taskID: id)
        lastNotifiedPercentage[id] = nil
        startDownloadWorker()
    }

    private func startDownloadWorker() {
        guard downloadWorker == nil else { return }
        downloadWorker = Task { [weak self] in await self?.processDownloadQueue() }
        updateIdleTimerPolicy()
    }

    private func processDownloadQueue() async {
        defer {
            downloadWorker = nil
            updateIdleTimerPolicy()
            if session != nil { workflow = .connected }
        }
        while let index = downloadTasks.firstIndex(where: { $0.status == .queued }) {
            guard session != nil else {
                downloadTasks[index].status = .failed
                downloadTasks[index].errorMessage = "相机连接已断开"
                continue
            }
            workflow = .downloading
            downloadTasks[index].status = .downloading
            let task = downloadTasks[index]
            let token = DownloadCancellationToken()
            downloadTokens[task.id] = token
            let finalURL = store.uniqueDownloadURL(named: task.asset.name)
            let partialURL = finalURL.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partialURL)
            let meter = DownloadProgressMeter(total: task.asset.size)
            do {
                if session?.transport == .wifi {
                    guard let wifiClient else { throw PTPError.disconnected }
                    try await wifiClient.download(task.asset, to: partialURL, cancellation: token) { [weak self] completed, total in
                        let report = meter.update(completed: completed, total: total)
                        Task { @MainActor [weak self] in self?.updateDownloadProgress(id: task.id, report: report) }
                    }
                } else {
                    _ = try await usbClient.download(task.asset, to: partialURL) { [weak self] value in
                        let report = meter.update(completed: value.completedBytes, total: value.totalBytes)
                        self?.updateDownloadProgress(id: task.id, report: report)
                    }
                }
                if token.isCancelled { throw CancellationError() }
                try? FileManager.default.removeItem(at: finalURL)
                try FileManager.default.moveItem(at: partialURL, to: finalURL)
                let attributes = try FileManager.default.attributesOfItem(atPath: finalURL.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? task.asset.size
                let record = DownloadRecord(name: finalURL.lastPathComponent, size: size, relativePath: finalURL.lastPathComponent, kind: task.asset.kind)
                downloads.insert(record, at: 0)
                if downloads.count > 100 { downloads = Array(downloads.prefix(100)) }
                try? await notifications.notifyDownloadCompleted(taskID: task.id, fileName: task.asset.name, totalBytes: size)
                lastNotifiedPercentage[task.id] = nil
                downloadTasks.removeAll { $0.id == task.id }
                if config.autoExport, [.image, .video].contains(task.asset.kind) {
                    try? await MediaLibraryService.saveToPhotos(fileURL: finalURL, kind: task.asset.kind)
                }
                notice = "下载完成：\(task.asset.name)"
                await diagnostics.log("DOWNLOAD_SUCCEEDED", phase: "DOWNLOAD", transport: session?.transport, message: task.asset.name)
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: partialURL)
                notifications.removeDownloadNotification(taskID: task.id)
                lastNotifiedPercentage[task.id] = nil
                downloadTasks.removeAll { $0.id == task.id }
                notice = "已取消下载"
            } catch PTPError.cancelled {
                try? FileManager.default.removeItem(at: partialURL)
                notifications.removeDownloadNotification(taskID: task.id)
                lastNotifiedPercentage[task.id] = nil
                downloadTasks.removeAll { $0.id == task.id }
                notice = "已取消下载"
            } catch {
                try? FileManager.default.removeItem(at: partialURL)
                if let failedIndex = downloadTasks.firstIndex(where: { $0.id == task.id }) {
                    downloadTasks[failedIndex].status = .failed
                    downloadTasks[failedIndex].errorMessage = error.localizedDescription
                }
                try? await notifications.notifyDownloadFailed(
                    taskID: task.id,
                    fileName: task.asset.name,
                    errorMessage: error.localizedDescription
                )
                lastNotifiedPercentage[task.id] = nil
                alertMessage = "下载失败：\(error.localizedDescription)"
                await diagnostics.log("DOWNLOAD_FAILED", phase: "DOWNLOAD", level: "ERROR", transport: session?.transport, message: task.asset.name, error: error)
            }
            downloadTokens[task.id] = nil
        }
    }

    private func updateDownloadProgress(id: String, report: DownloadProgressReport) {
        guard let index = downloadTasks.firstIndex(where: { $0.id == id }) else { return }
        downloadTasks[index].downloadedBytes = report.completed
        downloadTasks[index].totalBytes = report.total
        downloadTasks[index].bytesPerSecond = report.speed
        downloadTasks[index].remainingSeconds = report.eta
        let percentage = report.total > 0
            ? Int((Double(report.completed) / Double(report.total) * 100).rounded(.down))
            : 0
        let previous = lastNotifiedPercentage[id]
        guard previous == nil || percentage >= (previous ?? 0) + 5 || percentage >= 100 else { return }
        lastNotifiedPercentage[id] = percentage
        let task = downloadTasks[index]
        Task {
            try? await notifications.updateDownloadProgress(
                taskID: id,
                fileName: task.asset.name,
                downloadedBytes: report.completed,
                totalBytes: report.total,
                bytesPerSecond: report.speed.map { Double($0) },
                remainingSeconds: report.eta.map { TimeInterval($0) }
            )
        }
    }

    func url(for record: DownloadRecord) -> URL { store.url(for: record) }

    func deleteDownloads(ids: Set<UUID>) {
        let removing = downloads.filter { ids.contains($0.id) }
        removing.forEach { try? FileManager.default.removeItem(at: store.url(for: $0)) }
        downloads.removeAll { ids.contains($0.id) }
        notice = "已删除 \(removing.count) 个文件"
    }

    func importLUT(from source: URL) async {
        let securityScoped = source.startAccessingSecurityScopedResource()
        defer { if securityScoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: source, options: .mappedIfSafe)
            let parsed = try LUTProcessor.shared.parse(name: source.lastPathComponent, data: data)
            let destination = store.uniqueLUTURL(named: source.lastPathComponent)
            try data.write(to: destination, options: .atomic)
            let entry = LUTEntry(
                name: parsed.lut.name, format: parsed.format, dimension: parsed.lut.size,
                sourceName: source.lastPathComponent, storedFileName: destination.lastPathComponent
            )
            luts.insert(entry, at: 0)
            cache(lut: parsed.lut, id: entry.id)
            notice = "已导入 LUT：\(entry.name)"
        } catch { alertMessage = error.localizedDescription }
    }

    func lut(for entry: LUTEntry) throws -> CubeLUT {
        if let cached = lutCache[entry.id] { touchCache(entry.id); return cached }
        let url = store.lutDirectory.appendingPathComponent(entry.storedFileName)
        let parsed = try LUTProcessor.shared.parse(name: entry.sourceName, data: Data(contentsOf: url, options: .mappedIfSafe)).lut
        cache(lut: parsed, id: entry.id)
        return parsed
    }

    func updateLUT(_ entry: LUTEntry) {
        guard let index = luts.firstIndex(where: { $0.id == entry.id }) else { return }
        luts[index] = entry
    }

    func removeLUT(_ entry: LUTEntry) {
        try? FileManager.default.removeItem(at: store.lutDirectory.appendingPathComponent(entry.storedFileName))
        luts.removeAll { $0.id == entry.id }
        lutCache[entry.id] = nil
        lutCacheOrder.removeAll { $0 == entry.id }
    }

    private func cache(lut: CubeLUT, id: UUID) {
        lutCache[id] = lut
        touchCache(id)
        while lutCacheOrder.count > 8, let removing = lutCacheOrder.first {
            lutCacheOrder.removeFirst(); lutCache[removing] = nil
        }
    }

    private func touchCache(_ id: UUID) {
        lutCacheOrder.removeAll { $0 == id }; lutCacheOrder.append(id)
    }

    func saveWatermark(_ preset: WatermarkPreset) {
        if let index = watermarks.firstIndex(where: { $0.id == preset.id }) { watermarks[index] = preset }
        else { watermarks.append(preset) }
    }

    func removeWatermark(_ preset: WatermarkPreset) { watermarks.removeAll { $0.id == preset.id } }

    func saveLightScenes() { store.save(lightScenes: lightScenes) }

    func exportEdited(
        record: DownloadRecord,
        lutEntry: LUTEntry?,
        intensity: Double,
        watermark: WatermarkPreset?,
        rotation: Int = 0
    ) {
        guard exportProgress == nil else { return }
        exportProgress = 0
        Task {
            do {
                let sourceURL = store.url(for: record)
                let suffix = [lutEntry == nil ? nil : "LUT", watermark == nil ? nil : "WM"].compactMap { $0 }.joined(separator: "_")
                if record.kind == .video {
                    let output = store.uniqueDownloadURL(named: sourceURL.deletingPathExtension().lastPathComponent + "_\(suffix.isEmpty ? "EDIT" : suffix).mp4")
                    let lut = try lutEntry.map { try self.lut(for: $0) }
                    try await VideoProcessor.shared.export(
                        sourceURL: sourceURL,
                        destinationURL: output,
                        lut: lut,
                        intensity: intensity,
                        rotation: rotation,
                        watermark: watermark,
                        metadata: videoMetadata(for: record)
                    ) { [weak self] value in
                        Task { @MainActor [weak self] in self?.exportProgress = value }
                    }
                    addEditedRecord(url: output, kind: .video)
                    try? await MediaLibraryService.saveToPhotos(fileURL: output, kind: .video)
                } else {
                    let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                    guard var image = UIImage(data: data) else { throw MediaProcessingError.cannotDecodeImage }
                    let metadata = PhotoMetadataReader.read(from: data, fallback: PhotoMetadata(capturedAt: record.completedAt))
                    if let lutEntry { image = try LUTProcessor.shared.apply(try lut(for: lutEntry), to: image, intensity: intensity) }
                    if rotation % 360 != 0 { image = image.rotated(by: rotation) }
                    if let watermark { image = try WatermarkRenderer.shared.render(image: image, metadata: metadata, preset: watermark) }
                    let output = store.uniqueDownloadURL(named: sourceURL.deletingPathExtension().lastPathComponent + "_\(suffix).jpg")
                    try MediaLibraryService.writeJPEG(image: image, metadata: metadata, quality: jpegQuality(for: watermark), to: output)
                    addEditedRecord(url: output, kind: .image)
                    try? await MediaLibraryService.saveToPhotos(fileURL: output, kind: .image)
                }
                notice = "导出完成"
            } catch { alertMessage = error.localizedDescription }
            exportProgress = nil
        }
    }

    func exportRemoteImage(
        asset: PhotoAsset,
        image: UIImage,
        lutEntry: LUTEntry?,
        intensity: Double,
        watermark: WatermarkPreset?,
        rotation: Int
    ) {
        guard exportProgress == nil else { return }
        exportProgress = 0
        Task {
            do {
                var outputImage = image
                if let lutEntry { outputImage = try LUTProcessor.shared.apply(try lut(for: lutEntry), to: outputImage, intensity: intensity) }
                if rotation % 360 != 0 { outputImage = outputImage.rotated(by: rotation) }
                let metadata = PhotoMetadata(
                    cameraBrand: session?.details.manufacturer,
                    cameraModel: session?.details.model ?? session?.name,
                    lensModel: session?.details.lensName,
                    capturedAt: asset.capturedAt
                )
                if let watermark { outputImage = try WatermarkRenderer.shared.render(image: outputImage, metadata: metadata, preset: watermark) }
                let suffix = [lutEntry == nil ? nil : "LUT", watermark == nil ? nil : "WM"].compactMap { $0 }.joined(separator: "_")
                let stem = URL(fileURLWithPath: asset.name).deletingPathExtension().lastPathComponent
                let output = store.uniqueDownloadURL(named: "\(stem)_\(suffix.isEmpty ? "EDIT" : suffix).jpg")
                try MediaLibraryService.writeJPEG(image: outputImage, metadata: metadata, quality: jpegQuality(for: watermark), to: output)
                addEditedRecord(url: output, kind: .image)
                try? await MediaLibraryService.saveToPhotos(fileURL: output, kind: .image)
                notice = "导出完成"
            } catch { alertMessage = error.localizedDescription }
            exportProgress = nil
        }
    }

    /// Downloads selected camera images one at a time, applies the requested
    /// effects, saves the JPEGs in Downloads, and exports them to Photos.
    /// Videos are deliberately reported as skipped because they must first be
    /// downloaded and processed from the Downloads screen.
    func exportRemoteBatch(
        assets: [PhotoAsset],
        lutEntry: LUTEntry?,
        intensity: Double,
        watermark: WatermarkPreset?,
        rotation: Int
    ) {
        guard remoteBatchTask == nil, exportProgress == nil else {
            alertMessage = "已有导出任务正在运行"
            return
        }
        guard downloadWorker == nil else {
            alertMessage = "请等待当前原片下载任务完成后再批量处理"
            return
        }
        guard session != nil else {
            alertMessage = "相机连接已断开"
            return
        }

        var seenHandles = Set<UInt32>()
        let uniqueAssets = assets.filter { seenHandles.insert($0.handle).inserted }
        guard !uniqueAssets.isEmpty else {
            alertMessage = "请先选择要处理的照片"
            return
        }
        let normalizedRotation = ((rotation % 360) + 360) % 360
        guard lutEntry != nil || watermark != nil || normalizedRotation != 0 else {
            alertMessage = "请至少选择 LUT、水印或旋转效果"
            return
        }
        guard uniqueAssets.contains(where: { $0.kind == .image || $0.kind == .rawImage }) else {
            alertMessage = "视频需先下载到本机，再从下载页应用 LUT 或水印"
            return
        }

        exportProgress = 0
        remoteBatchStatus = "正在准备批量处理"
        workflow = .downloading
        remoteBatchTask = Task { [weak self] in
            guard let self else { return }
            await self.processRemoteBatch(
                assets: uniqueAssets,
                lutEntry: lutEntry,
                intensity: min(max(intensity, 0), 1),
                watermark: watermark,
                rotation: normalizedRotation
            )
        }
        updateIdleTimerPolicy()
    }

    func cancelRemoteBatchExport() {
        guard let remoteBatchTask else { return }
        remoteBatchStatus = "正在取消批量处理"
        remoteBatchDownloadToken?.cancel()
        if session?.transport == .usb, let remoteBatchAssetHandle {
            usbClient.cancelDownload(for: remoteBatchAssetHandle)
        }
        remoteBatchTask.cancel()
    }

    private func processRemoteBatch(
        assets: [PhotoAsset],
        lutEntry: LUTEntry?,
        intensity: Double,
        watermark: WatermarkPreset?,
        rotation: Int
    ) async {
        defer {
            remoteBatchDownloadToken = nil
            remoteBatchAssetHandle = nil
            remoteBatchTask = nil
            remoteBatchStatus = nil
            exportProgress = nil
            if session != nil { workflow = .connected }
            updateIdleTimerPolicy()
        }

        let loadedLUT: CubeLUT?
        do {
            loadedLUT = try lutEntry.map { try lut(for: $0) }
        } catch {
            alertMessage = "无法载入 LUT：\(error.localizedDescription)"
            return
        }

        let processable = assets.filter { $0.kind == .image || $0.kind == .rawImage }
        var failures = assets.compactMap { asset -> String? in
            switch asset.kind {
            case .video: return "\(asset.name)：视频需先下载后处理"
            case .unknown: return "\(asset.name)：不支持的文件类型"
            case .image, .rawImage: return nil
            }
        }
        let total = processable.count
        guard total > 0 else {
            alertMessage = failures.joined(separator: "\n")
            return
        }

        let suffixParts = [
            lutEntry == nil ? nil : "LUT",
            watermark == nil ? nil : "WM",
            rotation == 0 ? nil : "R\(rotation)"
        ].compactMap { $0 }
        let suffix = suffixParts.isEmpty ? "EDIT" : suffixParts.joined(separator: "_")
        let quality = jpegQuality(for: watermark)
        let sessionSnapshot = session
        var completed = 0
        var wasCancelled = false

        await diagnostics.log(
            "REMOTE_BATCH_STARTED",
            phase: "REMOTE_BATCH",
            transport: sessionSnapshot?.transport,
            message: "selected=\(assets.count) processable=\(total)"
        )

        for (index, asset) in processable.enumerated() {
            if Task.isCancelled { wasCancelled = true; break }

            let safeName = asset.name
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            let sourceURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CameraBridge-Batch-\(UUID().uuidString)-\(safeName)")
            defer { try? FileManager.default.removeItem(at: sourceURL) }

            let stem = URL(fileURLWithPath: safeName).deletingPathExtension().lastPathComponent
            let outputURL = store.uniqueDownloadURL(named: "\(stem)_\(suffix).jpg")
            var outputWasAdded = false
            let token = DownloadCancellationToken()
            remoteBatchDownloadToken = token
            remoteBatchAssetHandle = asset.handle
            remoteBatchStatus = "正在下载 \(index + 1)/\(total) · \(asset.name)"

            do {
                if sessionSnapshot?.transport == .wifi {
                    guard let wifiClient else { throw PTPError.disconnected }
                    try await wifiClient.download(asset, to: sourceURL, cancellation: token) { [weak self] bytes, expected in
                        Task { @MainActor [weak self] in
                            self?.updateRemoteBatchProgress(
                                fileCompleted: bytes,
                                fileTotal: expected > 0 ? expected : asset.size,
                                itemIndex: index,
                                itemCount: total
                            )
                        }
                    }
                } else {
                    _ = try await usbClient.download(asset, to: sourceURL) { [weak self] progress in
                        Task { @MainActor [weak self] in
                            self?.updateRemoteBatchProgress(
                                fileCompleted: progress.completedBytes,
                                fileTotal: progress.totalBytes > 0 ? progress.totalBytes : asset.size,
                                itemIndex: index,
                                itemCount: total
                            )
                        }
                    }
                }
                guard !Task.isCancelled, !token.isCancelled else { throw CancellationError() }

                exportProgress = (Double(index) + 0.65) / Double(total)
                remoteBatchStatus = "正在处理 \(index + 1)/\(total) · \(asset.name)"
                let fallbackMetadata = PhotoMetadata(
                    cameraBrand: sessionSnapshot?.details.manufacturer,
                    cameraModel: sessionSnapshot?.details.model ?? sessionSnapshot?.name,
                    lensModel: sessionSnapshot?.details.lensName,
                    iso: sessionSnapshot?.details.recentISO,
                    shutterSpeed: sessionSnapshot?.details.recentShutter,
                    aperture: sessionSnapshot?.details.recentAperture,
                    focalLength: sessionSnapshot?.details.recentFocalLength,
                    capturedAt: asset.capturedAt
                )

                try await Task.detached(priority: .userInitiated) {
                    let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                    guard var image = UIImage(data: data) else { throw MediaProcessingError.cannotDecodeImage }
                    let metadata = PhotoMetadataReader.read(from: data, fallback: fallbackMetadata)
                    if let loadedLUT {
                        image = try LUTProcessor.shared.apply(loadedLUT, to: image, intensity: intensity)
                    }
                    if rotation != 0 { image = image.rotated(by: rotation) }
                    if let watermark {
                        image = try WatermarkRenderer.shared.render(image: image, metadata: metadata, preset: watermark)
                    }
                    try MediaLibraryService.writeJPEG(
                        image: image,
                        metadata: metadata,
                        quality: quality,
                        to: outputURL
                    )
                }.value
                guard !Task.isCancelled else { throw CancellationError() }

                addEditedRecord(url: outputURL, kind: .image)
                if downloads.count > 100 { downloads = Array(downloads.prefix(100)) }
                outputWasAdded = true
                completed += 1
                exportProgress = (Double(index) + 0.90) / Double(total)
                remoteBatchStatus = "正在写入系统照片 \(index + 1)/\(total)"
                do {
                    try await MediaLibraryService.saveToPhotos(fileURL: outputURL, kind: .image)
                } catch {
                    failures.append("\(asset.name)：已存入下载，但系统照片写入失败（\(error.localizedDescription)）")
                }
                exportProgress = Double(index + 1) / Double(total)
                await diagnostics.log(
                    "REMOTE_BATCH_ITEM_SUCCEEDED",
                    phase: "REMOTE_BATCH",
                    transport: sessionSnapshot?.transport,
                    message: asset.name
                )
            } catch is CancellationError {
                if !outputWasAdded { try? FileManager.default.removeItem(at: outputURL) }
                wasCancelled = true
                break
            } catch PTPError.cancelled {
                if !outputWasAdded { try? FileManager.default.removeItem(at: outputURL) }
                wasCancelled = true
                break
            } catch {
                if !outputWasAdded { try? FileManager.default.removeItem(at: outputURL) }
                failures.append("\(asset.name)：\(error.localizedDescription)")
                exportProgress = Double(index + 1) / Double(total)
                await diagnostics.log(
                    "REMOTE_BATCH_ITEM_FAILED",
                    phase: "REMOTE_BATCH",
                    level: "ERROR",
                    transport: sessionSnapshot?.transport,
                    message: asset.name,
                    error: error
                )
            }
            remoteBatchDownloadToken = nil
            remoteBatchAssetHandle = nil
        }

        if wasCancelled {
            notice = completed > 0 ? "已取消批量处理 · 已完成 \(completed) 个" : "已取消批量处理"
            return
        }

        notice = failures.isEmpty
            ? "批量处理完成 · \(completed) 个文件已存入下载和系统照片"
            : "批量处理完成 \(completed) 个，另有 \(failures.count) 条提示"
        if !failures.isEmpty {
            let visible = failures.prefix(5).joined(separator: "\n")
            let remaining = failures.count - min(failures.count, 5)
            alertMessage = remaining > 0 ? "\(visible)\n另有 \(remaining) 项未显示" : visible
        }
        await diagnostics.log(
            "REMOTE_BATCH_FINISHED",
            phase: "REMOTE_BATCH",
            transport: sessionSnapshot?.transport,
            message: "completed=\(completed) notices=\(failures.count)"
        )
    }

    private func updateRemoteBatchProgress(
        fileCompleted: Int64,
        fileTotal: Int64,
        itemIndex: Int,
        itemCount: Int
    ) {
        guard remoteBatchTask != nil, itemCount > 0 else { return }
        let fraction = fileTotal > 0
            ? min(max(Double(fileCompleted) / Double(fileTotal), 0), 1)
            : 0
        exportProgress = (Double(itemIndex) + fraction * 0.65) / Double(itemCount)
    }

    func exportBatch(
        records: [DownloadRecord],
        lutEntry: LUTEntry?,
        intensity: Double,
        watermark: WatermarkPreset?,
        rotation: Int
    ) {
        guard exportProgress == nil, !records.isEmpty else { return }
        exportProgress = 0
        Task {
            var completed = 0
            var failures: [String] = []
            let loadedLUT: CubeLUT? = lutEntry.flatMap { try? self.lut(for: $0) }
            for record in records {
                do {
                    let sourceURL = store.url(for: record)
                    let suffix = [lutEntry == nil ? nil : "LUT", watermark == nil ? nil : "WM"].compactMap { $0 }.joined(separator: "_")
                    if record.kind == .video {
                        let output = store.uniqueDownloadURL(named: sourceURL.deletingPathExtension().lastPathComponent + "_\(suffix.isEmpty ? "EDIT" : suffix).mp4")
                        try await VideoProcessor.shared.export(
                            sourceURL: sourceURL,
                            destinationURL: output,
                            lut: loadedLUT,
                            intensity: intensity,
                            rotation: rotation,
                            watermark: watermark,
                            metadata: videoMetadata(for: record)
                        ) { [weak self] child in
                            Task { @MainActor [weak self] in self?.exportProgress = (Double(completed) + child) / Double(records.count) }
                        }
                        addEditedRecord(url: output, kind: .video)
                        try? await MediaLibraryService.saveToPhotos(fileURL: output, kind: .video)
                    } else {
                        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
                        guard var image = UIImage(data: data) else { throw MediaProcessingError.cannotDecodeImage }
                        let metadata = PhotoMetadataReader.read(from: data, fallback: PhotoMetadata(capturedAt: record.completedAt))
                        if let loadedLUT { image = try LUTProcessor.shared.apply(loadedLUT, to: image, intensity: intensity) }
                        if rotation % 360 != 0 { image = image.rotated(by: rotation) }
                        if let watermark { image = try WatermarkRenderer.shared.render(image: image, metadata: metadata, preset: watermark) }
                        let output = store.uniqueDownloadURL(named: sourceURL.deletingPathExtension().lastPathComponent + "_\(suffix.isEmpty ? "EDIT" : suffix).jpg")
                        try MediaLibraryService.writeJPEG(image: image, metadata: metadata, quality: jpegQuality(for: watermark), to: output)
                        addEditedRecord(url: output, kind: .image)
                        try? await MediaLibraryService.saveToPhotos(fileURL: output, kind: .image)
                    }
                    completed += 1
                    exportProgress = Double(completed) / Double(records.count)
                } catch { failures.append("\(record.name)：\(error.localizedDescription)") }
            }
            notice = failures.isEmpty ? "已完成 \(completed) 个文件" : "完成 \(completed) 个，失败 \(failures.count) 个"
            if !failures.isEmpty { alertMessage = failures.prefix(3).joined(separator: "\n") }
            exportProgress = nil
        }
    }

    private func addEditedRecord(url: URL, kind: MediaKind) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
        downloads.insert(DownloadRecord(name: url.lastPathComponent, size: size, relativePath: url.lastPathComponent, kind: kind, edited: true), at: 0)
    }

    private func jpegQuality(for watermark: WatermarkPreset?) -> Double {
        if let watermark { return min(max(watermark.quality, 0.5), 1) }
        return min(max(Double(config.jpegQuality) / 100, 0.1), 1)
    }

    private func videoMetadata(for record: DownloadRecord) -> PhotoMetadata {
        PhotoMetadata(
            cameraBrand: session?.details.manufacturer,
            cameraModel: session?.details.model ?? session?.name,
            lensModel: session?.details.lensName,
            iso: session?.details.recentISO,
            shutterSpeed: session?.details.recentShutter,
            aperture: session?.details.recentAperture,
            focalLength: session?.details.recentFocalLength,
            capturedAt: session?.details.recentCapturedAt ?? record.completedAt
        )
    }

    private func updateIdleTimerPolicy() {
        UIApplication.shared.isIdleTimerDisabled = config.keepWiFiAlive && (downloadWorker != nil || exportProgress != nil)
    }

    func exportDiagnostics() async -> URL? {
        do { return try await diagnostics.export(into: store.diagnosticsDirectory, session: session, config: config) }
        catch { alertMessage = error.localizedDescription; return nil }
    }

    func diagnosticText() async -> String { await diagnostics.text() }
    func clearDiagnostics() { Task { await diagnostics.clear(); notice = "诊断数据已清除" } }
    func clearThumbnailCache() { thumbnails.removeAll(); notice = "缩略图缓存已清理" }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            endBackgroundTask()
            guard let session else { return }
            Task {
                let connected = session.transport == .wifi ? ((try? await wifiClient?.checkConnection()) != nil) : usbClient.checkConnection()
                if !connected { self.session = nil; workflow = .waiting; notice = "相机连接已断开" }
            }
        case .background:
            guard downloadWorker != nil, backgroundTask == .invalid else { return }
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishCameraChunk") { [weak self] in
                Task { @MainActor [weak self] in
                    self?.downloadTokens.values.forEach { $0.cancel() }
                    self?.endBackgroundTask()
                }
            }
        default: break
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func fail(_ error: Error, event: String, phase: String, transport: CameraTransport) async {
        workflow = .error(error.localizedDescription)
        alertMessage = error.localizedDescription
        notice = "操作失败"
        await diagnostics.log(event, phase: phase, level: "ERROR", transport: transport, message: error.localizedDescription, error: error)
    }
}

struct DownloadProgressReport {
    let completed: Int64
    let total: Int64
    let speed: Int64?
    let eta: Int?
}

final class DownloadProgressMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDate = Date()
    private var lastBytes: Int64 = 0
    private var smoothedSpeed: Double?
    private let fallbackTotal: Int64

    init(total: Int64) { fallbackTotal = max(total, 0) }

    func update(completed: Int64, total: Int64) -> DownloadProgressReport {
        lock.withLock {
            let now = Date()
            let normalizedTotal = max(total > 0 ? total : fallbackTotal, 0)
            let normalizedCompleted = min(max(completed, 0), normalizedTotal)
            let interval = now.timeIntervalSince(lastDate)
            if interval > 0, normalizedCompleted >= lastBytes {
                let instantaneous = Double(normalizedCompleted - lastBytes) / interval
                if instantaneous > 0 { smoothedSpeed = smoothedSpeed.map { $0 * 0.75 + instantaneous * 0.25 } ?? instantaneous }
                lastDate = now
                lastBytes = normalizedCompleted
            }
            let remaining = max(normalizedTotal - normalizedCompleted, 0)
            let eta = smoothedSpeed.flatMap { $0 > 0 ? Int(Double(remaining) / $0) : nil }
            return DownloadProgressReport(completed: normalizedCompleted, total: normalizedTotal, speed: smoothedSpeed.map(Int64.init), eta: eta)
        }
    }
}

private extension UIImage {
    func rotated(by degrees: Int) -> UIImage {
        let turns = ((degrees % 360) + 360) % 360
        guard turns != 0 else { return self }
        let radians = CGFloat(turns) * .pi / 180
        let swap = turns == 90 || turns == 270
        let outputSize = swap ? CGSize(width: size.height, height: size.width) : size
        return UIGraphicsImageRenderer(size: outputSize).image { context in
            context.cgContext.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            context.cgContext.rotate(by: radians)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }
}
