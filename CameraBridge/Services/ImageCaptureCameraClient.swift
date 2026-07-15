import Combine
import CoreGraphics
import Foundation
@preconcurrency import ImageCaptureCore

struct ImageCaptureCameraDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let productKind: String?
    let serialNumber: String?
    let vendorID: Int32
    let productID: Int32
}

struct ImageCaptureTransferProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64
    let fractionCompleted: Double
    let isCancellable: Bool
    let isCancelled: Bool
}

enum ImageCaptureConnectionState: Equatable {
    case idle
    case discovering
    case connecting(String)
    case connected(String)
    case disconnected
    case failed(String)
}

enum ImageCaptureCameraError: LocalizedError {
    case authorizationDenied
    case authorizationRestricted
    case noCamera
    case cameraNotFound
    case cameraDisconnected
    case assetNotFound(UInt32)
    case invalidReadRange
    case transferAlreadyRunning
    case downloadCouldNotStart
    case downloadedFileMissing
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "未获得外接相机访问权限，请在系统设置中允许 Camera Bridge 访问相机。"
        case .authorizationRestricted:
            "此设备当前限制了外接相机访问。"
        case .noCamera:
            "未检测到可读取的 USB 相机。"
        case .cameraNotFound:
            "所选 USB 相机已不可用。"
        case .cameraDisconnected:
            "USB 相机连接已断开。"
        case let .assetNotFound(handle):
            "相机中找不到文件句柄 \(handle)。"
        case .invalidReadRange:
            "请求的文件读取范围无效。"
        case .transferAlreadyRunning:
            "相机正在传输另一个文件，请等待当前任务完成。"
        case .downloadCouldNotStart:
            "相机未能启动文件传输。"
        case .downloadedFileMissing:
            "相机报告传输完成，但没有生成下载文件。"
        case .invalidDestination:
            "下载目标必须是有效的本地文件 URL。"
        }
    }
}

/// USB/PTP camera adapter backed by ImageCaptureCore.
///
/// The class is main-actor isolated because ImageCaptureCore device objects and
/// their delegates are stateful Objective-C objects. AppModel can either observe
/// the published state or call the async methods directly.
@MainActor
final class ImageCaptureCameraClient: NSObject, ObservableObject {
    @Published private(set) var connectionState: ImageCaptureConnectionState = .idle
    @Published private(set) var authorizationStatus: ICAuthorizationStatus = .notDetermined
    @Published private(set) var discoveredCameras: [ImageCaptureCameraDescriptor] = []
    @Published private(set) var availableAssets: [PhotoAsset] = []
    @Published private(set) var catalogProgress: Double = 0
    @Published private(set) var transferProgress: [UInt32: ImageCaptureTransferProgress] = [:]

    private let browser = ICDeviceBrowser()
    private var camerasByID: [String: ICCameraDevice] = [:]
    private var filesByHandle: [UInt32: ICCameraFile] = [:]
    private var connectedCamera: ICCameraDevice?
    private var activeDownloads: [UInt32: ActiveDownload] = [:]
    private var isDisconnecting = false

    override init() {
        super.init()
        browser.delegate = self
        // Filtering by the camera type is sufficient on iOS. Device callbacks
        // are additionally checked for a USB transport before being published.
        browser.browsedDeviceTypeMask = .camera
    }

    // MARK: - Discovery and session lifecycle

    func startDiscovery() async throws {
        let status = await browser.requestContentsAuthorization()
        authorizationStatus = status

        if status == .denied {
            connectionState = .failed(ImageCaptureCameraError.authorizationDenied.localizedDescription)
            throw ImageCaptureCameraError.authorizationDenied
        }
        if status == .restricted {
            connectionState = .failed(ImageCaptureCameraError.authorizationRestricted.localizedDescription)
            throw ImageCaptureCameraError.authorizationRestricted
        }
        guard status == .authorized else {
            connectionState = .failed(ImageCaptureCameraError.authorizationDenied.localizedDescription)
            throw ImageCaptureCameraError.authorizationDenied
        }

        guard !browser.isBrowsing else { return }
        if connectedCamera == nil { connectionState = .discovering }
        browser.start()
    }

    func stopDiscovery() {
        guard browser.isBrowsing else { return }
        browser.stop()
        if connectedCamera == nil { connectionState = .idle }
    }

    /// Opens the selected camera, or the first discovered USB camera when nil.
    @discardableResult
    func connect(to descriptor: ImageCaptureCameraDescriptor? = nil) async throws -> CameraSession {
        let selectedID = descriptor?.id ?? discoveredCameras.first?.id
        guard let selectedID else { throw ImageCaptureCameraError.noCamera }
        guard let camera = camerasByID[selectedID] else { throw ImageCaptureCameraError.cameraNotFound }

        if connectedCamera === camera, camera.hasOpenSession {
            refreshAssets()
            return session(for: camera)
        }
        if connectedCamera != nil { await disconnect() }

        connectionState = .connecting(selectedID)
        camera.delegate = self
        connectedCamera = camera
        catalogProgress = 0

        do {
            try await camera.requestOpenSession()
            await waitForInitialCatalog(on: camera)
            refreshAssets()
            connectionState = .connected(selectedID)
            return session(for: camera)
        } catch {
            camera.delegate = nil
            connectedCamera = nil
            filesByHandle.removeAll()
            availableAssets.removeAll()
            connectionState = .failed(error.localizedDescription)
            throw error
        }
    }

    func disconnect() async {
        guard let camera = connectedCamera else {
            connectionState = .disconnected
            return
        }

        isDisconnecting = true
        terminateDownloads(with: CancellationError())
        if camera.hasOpenSession {
            try? await camera.requestCloseSession()
        }
        camera.delegate = nil
        connectedCamera = nil
        filesByHandle.removeAll()
        availableAssets.removeAll()
        catalogProgress = 0
        connectionState = .disconnected
        isDisconnecting = false
    }

    func checkConnection() -> Bool {
        connectedCamera?.hasOpenSession == true
    }

    // MARK: - Assets

    @discardableResult
    func refreshAssets() -> [PhotoAsset] {
        guard let camera = connectedCamera, camera.hasOpenSession else {
            filesByHandle.removeAll()
            availableAssets.removeAll()
            catalogProgress = 0
            return []
        }

        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        var mappedFiles: [UInt32: ICCameraFile] = [:]
        var mappedAssets: [PhotoAsset] = []
        var usedHandles = Set<UInt32>()
        var syntheticHandle = UInt32.max

        for file in files {
            var handle = file.ptpObjectHandle
            if handle == 0 || usedHandles.contains(handle) {
                while usedHandles.contains(syntheticHandle) || syntheticHandle == 0 {
                    syntheticHandle &-= 1
                }
                handle = syntheticHandle
                syntheticHandle &-= 1
            }
            usedHandles.insert(handle)

            let name = file.originalFilename ?? file.name ?? "IMG_\(handle)"
            let asset = PhotoAsset(
                handle: handle,
                name: name,
                size: max(Int64(file.fileSize), 0),
                format: ptpFormat(for: file, named: name),
                capturedAt: file.exifCreationDate
                    ?? file.fileCreationDate
                    ?? file.creationDate
                    ?? file.fileModificationDate
                    ?? file.modificationDate
                    ?? .distantPast
            )
            mappedFiles[handle] = file
            mappedAssets.append(asset)
        }

        filesByHandle = mappedFiles
        availableAssets = mappedAssets.sorted {
            if $0.capturedAt == $1.capturedAt { return $0.name > $1.name }
            return $0.capturedAt > $1.capturedAt
        }
        catalogProgress = min(max(Double(camera.contentCatalogPercentCompleted) / 100, 0), 1)
        return availableAssets
    }

    func assets(offset: Int = 0, limit: Int = 250) throws -> [PhotoAsset] {
        guard connectedCamera?.hasOpenSession == true else {
            throw ImageCaptureCameraError.cameraDisconnected
        }
        guard offset >= 0, limit >= 0 else { throw ImageCaptureCameraError.invalidReadRange }
        return Array(availableAssets.dropFirst(offset).prefix(limit))
    }

    func hasMoreAssets(after offset: Int) -> Bool {
        offset < availableAssets.count
    }

    func thumbnail(for asset: PhotoAsset) async throws -> Data? {
        let file = try file(for: asset)
        let data = try await file.requestThumbnailData()
        return data.isEmpty ? nil : data
    }

    func imageHeader(for asset: PhotoAsset, maximumLength: Int = 256 * 1_024) async throws -> Data? {
        let data = try await read(asset, offset: 0, length: maximumLength)
        return data.isEmpty ? nil : data
    }

    /// Reads a bounded segment without downloading the complete object.
    func read(_ asset: PhotoAsset, offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, length >= 0, length <= 64 * 1_024 * 1_024 else {
            throw ImageCaptureCameraError.invalidReadRange
        }
        guard length > 0 else { return Data() }

        let file = try file(for: asset)
        let knownSize = max(Int64(file.fileSize), 0)
        if knownSize > 0, offset >= knownSize { return Data() }
        let requestedLength = knownSize > 0
            ? min(Int64(length), knownSize - offset)
            : Int64(length)
        guard requestedLength > 0 else { return Data() }
        return try await file.requestReadData(
            atOffset: off_t(offset),
            length: off_t(requestedLength)
        )
    }

    // MARK: - Downloads

    /// Downloads through ImageCaptureCore into a private staging directory and
    /// atomically commits the finished file to `destination`.
    @discardableResult
    func download(
        _ asset: PhotoAsset,
        to destination: URL,
        progress progressHandler: @escaping (ImageCaptureTransferProgress) -> Void = { _ in }
    ) async throws -> URL {
        guard destination.isFileURL, !destination.lastPathComponent.isEmpty else {
            throw ImageCaptureCameraError.invalidDestination
        }
        guard activeDownloads.isEmpty else {
            throw ImageCaptureCameraError.transferAlreadyRunning
        }

        let file = try file(for: asset)
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraBridge-USB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectory) }

        let expectedStagedURL = stagingDirectory.appendingPathComponent(destination.lastPathComponent)
        let gate = DownloadContinuationGate()
        let returnedPath = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let options: [ICDownloadOption: Any] = [
                    .downloadsDirectoryURL: stagingDirectory,
                    .saveAsFilename: destination.lastPathComponent,
                    .overwrite: true
                ]
                let imageCaptureProgress = file.requestDownload(options: options) { [weak self] path, error in
                    Task { @MainActor in
                        self?.finishActiveDownload(for: asset.handle)
                        gate.finish(path: path, error: error)
                    }
                }

                guard let imageCaptureProgress else {
                    finishActiveDownload(for: asset.handle)
                    gate.finish(path: nil, error: ImageCaptureCameraError.downloadCouldNotStart)
                    return
                }
                guard gate.attach(imageCaptureProgress) else {
                    imageCaptureProgress.cancel()
                    return
                }
                beginProgressPolling(
                    handle: asset.handle,
                    asset: asset,
                    progress: imageCaptureProgress,
                    gate: gate,
                    handler: progressHandler
                )
            }
        } onCancel: {
            gate.cancel()
            Task { @MainActor [weak self] in
                self?.cancelDownload(for: asset.handle)
            }
        }

        let stagedURL = resolvedDownloadedURL(
            returnedPath: returnedPath,
            expectedURL: expectedStagedURL,
            stagingDirectory: stagingDirectory
        )
        guard let stagedURL, FileManager.default.fileExists(atPath: stagedURL.path) else {
            throw ImageCaptureCameraError.downloadedFileMissing
        }

        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: stagedURL)
        } else {
            try FileManager.default.moveItem(at: stagedURL, to: destination)
        }
        return destination
    }

    func cancelDownload(for handle: UInt32) {
        guard let active = activeDownloads[handle] else { return }
        active.gate.cancel()
        active.progress.cancel()
    }

    func cancelAllDownloads() {
        for handle in activeDownloads.keys { cancelDownload(for: handle) }
    }

    // MARK: - Private helpers

    private func waitForInitialCatalog(on camera: ICCameraDevice) async {
        // Large cards may continue cataloguing after the session is open. Wait
        // briefly for an initial usable snapshot; delegates keep refreshing it.
        let deadline = Date().addingTimeInterval(15)
        while camera.hasOpenSession,
              camera.contentCatalogPercentCompleted < 100,
              camera.mediaFiles == nil,
              Date() < deadline {
            try? await Task<Never, Never>.sleep(nanoseconds: 200_000_000)
        }
    }

    private func file(for asset: PhotoAsset) throws -> ICCameraFile {
        guard connectedCamera?.hasOpenSession == true else {
            throw ImageCaptureCameraError.cameraDisconnected
        }
        guard let file = filesByHandle[asset.handle] else {
            throw ImageCaptureCameraError.assetNotFound(asset.handle)
        }
        return file
    }

    private func session(for camera: ICCameraDevice) -> CameraSession {
        let name = camera.name ?? camera.productKind ?? "USB 相机"
        return CameraSession(
            name: name,
            host: "USB",
            port: 0,
            transport: .usb,
            details: CameraDetails(
                manufacturer: manufacturer(for: camera),
                model: camera.productKind ?? camera.name,
                deviceVersion: nil,
                serialNumber: nil
            )
        )
    }

    private func manufacturer(for camera: ICCameraDevice) -> String? {
        if camera.usbVendorID == 0x04B0 { return "Nikon" }
        let text = [camera.name, camera.productKind].compactMap { $0 }.joined(separator: " ")
        for name in ["Nikon", "Canon", "Sony", "Fujifilm", "Panasonic", "Olympus", "OM Digital"] {
            if text.localizedCaseInsensitiveContains(name) { return name }
        }
        return nil
    }

    private func ptpFormat(for file: ICCameraFile, named name: String) -> UInt16 {
        if file.isRaw { return 0x3000 }
        return switch name.split(separator: ".").last?.lowercased() {
        case "jpg", "jpeg", "heic", "heif", "webp": 0x3801
        case "png": 0x380B
        case "mov": 0x300C
        case "mp4", "m4v", "3gp": 0x380D
        case "nef", "nrw", "cr2", "arw", "dng", "raf": 0x3000
        default: 0
        }
    }

    private func isUSBCamera(_ device: ICDevice) -> Bool {
        guard device is ICCameraDevice else { return false }
        return device.transportType == ICDeviceTransport.transportTypeUSB.rawValue
            || device.transportType == ICDeviceTransport.transportTypeMassStorage.rawValue
            || device.usbVendorID != 0
            || device.usbProductID != 0
    }

    private func deviceID(for device: ICDevice) -> String {
        device.uuidString
            ?? String(format: "%08X:%04X:%04X", device.usbLocationID, device.usbVendorID, device.usbProductID)
    }

    private func rebuildDiscoveredCameras() {
        discoveredCameras = camerasByID.map { id, camera in
            ImageCaptureCameraDescriptor(
                id: id,
                name: camera.name ?? camera.productKind ?? "USB 相机",
                productKind: camera.productKind,
                serialNumber: nil,
                vendorID: camera.usbVendorID,
                productID: camera.usbProductID
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func handleRemovedDevice(_ device: ICDevice) {
        let id = deviceID(for: device)
        camerasByID[id] = nil
        rebuildDiscoveredCameras()

        guard connectedCamera === device else { return }
        terminateDownloads(with: ImageCaptureCameraError.cameraDisconnected)
        connectedCamera?.delegate = nil
        connectedCamera = nil
        filesByHandle.removeAll()
        availableAssets.removeAll()
        catalogProgress = 0
        if !isDisconnecting {
            connectionState = .failed(ImageCaptureCameraError.cameraDisconnected.localizedDescription)
        }
    }

    private func beginProgressPolling(
        handle: UInt32,
        asset: PhotoAsset,
        progress: Progress,
        gate: DownloadContinuationGate,
        handler: @escaping (ImageCaptureTransferProgress) -> Void
    ) {
        activeDownloads[handle] = ActiveDownload(
            gate: gate,
            progress: progress,
            asset: asset,
            handler: handler,
            pollingTask: nil
        )
        let pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let active = self.activeDownloads[handle] else { return }
                self.publishProgress(for: active)
                try? await Task<Never, Never>.sleep(nanoseconds: 200_000_000)
            }
        }
        activeDownloads[handle]?.pollingTask = pollingTask
        publishProgress(for: activeDownloads[handle]!)
    }

    private func publishProgress(for active: ActiveDownload) {
        let foundationProgress = active.progress
        let fallbackTotal = max(active.asset.size, 0)
        let progressTotal = fallbackTotal > 0
            ? fallbackTotal
            : max(foundationProgress.totalUnitCount, 0)
        let rawFraction = foundationProgress.fractionCompleted
        let fraction = rawFraction.isFinite ? min(max(rawFraction, 0), 1) : 0
        let completed = foundationProgress.completedUnitCount > 0
            ? foundationProgress.completedUnitCount
            : Int64(Double(progressTotal) * fraction)
        let report = ImageCaptureTransferProgress(
            completedBytes: min(max(completed, 0), max(progressTotal, 0)),
            totalBytes: max(progressTotal, 0),
            fractionCompleted: fraction,
            isCancellable: foundationProgress.isCancellable,
            isCancelled: foundationProgress.isCancelled
        )
        transferProgress[active.asset.handle] = report
        active.handler(report)
    }

    private func finishActiveDownload(for handle: UInt32) {
        guard let active = activeDownloads.removeValue(forKey: handle) else { return }
        publishProgress(for: active)
        active.pollingTask?.cancel()
        transferProgress[handle] = nil
    }

    private func terminateDownloads(with error: Error) {
        guard !activeDownloads.isEmpty else { return }
        let downloads = activeDownloads
        activeDownloads.removeAll()
        for (handle, active) in downloads {
            active.progress.cancel()
            active.pollingTask?.cancel()
            transferProgress[handle] = nil
            active.gate.finish(path: nil, error: error)
        }
    }

    private func resolvedDownloadedURL(
        returnedPath: String?,
        expectedURL: URL,
        stagingDirectory: URL
    ) -> URL? {
        if FileManager.default.fileExists(atPath: expectedURL.path) { return expectedURL }
        guard let returnedPath, !returnedPath.isEmpty else { return nil }
        let returnedURL = returnedPath.hasPrefix("/")
            ? URL(fileURLWithPath: returnedPath)
            : stagingDirectory.appendingPathComponent(returnedPath)
        return FileManager.default.fileExists(atPath: returnedURL.path) ? returnedURL : nil
    }
}

// MARK: - ImageCaptureCore delegates

extension ImageCaptureCameraClient: ICDeviceBrowserDelegate {
    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard isUSBCamera(device), let camera = device as? ICCameraDevice else { return }
        camerasByID[deviceID(for: camera)] = camera
        rebuildDiscoveredCameras()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        handleRemovedDevice(device)
    }
}

extension ImageCaptureCameraClient: ICCameraDeviceDelegate {
    func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error { connectionState = .failed(error.localizedDescription) }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) {
        guard connectedCamera === device, !isDisconnecting else { return }
        terminateDownloads(with: error ?? ImageCaptureCameraError.cameraDisconnected)
        connectedCamera?.delegate = nil
        connectedCamera = nil
        filesByHandle.removeAll()
        availableAssets.removeAll()
        catalogProgress = 0
        if let error {
            connectionState = .failed(error.localizedDescription)
        } else {
            connectionState = .disconnected
        }
    }

    func didRemove(_ device: ICDevice) {
        handleRemovedDevice(device)
    }

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard connectedCamera === device else { return }
        catalogProgress = 1
        refreshAssets()
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        guard connectedCamera === camera else { return }
        refreshAssets()
    }

    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        guard connectedCamera === camera else { return }
        refreshAssets()
    }

    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {
        guard connectedCamera === camera else { return }
        refreshAssets()
    }

    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveMetadata metadata: [AnyHashable: Any]?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    func cameraDevice(
        _ camera: ICCameraDevice,
        didReceiveThumbnail thumbnail: CGImage?,
        for item: ICCameraItem,
        error: (any Error)?
    ) {}

    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        guard connectedCamera === camera else { return }
        refreshAssets()
    }

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        guard connectedCamera === device else { return }
        connectionState = .failed(ImageCaptureCameraError.authorizationRestricted.localizedDescription)
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        guard let camera = device as? ICCameraDevice, connectedCamera === camera else { return }
        refreshAssets()
    }

    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // The content-change callbacks above are the authoritative asset source.
        // Keeping this method explicit also ensures the event channel is drained.
    }
}

private struct ActiveDownload {
    let gate: DownloadContinuationGate
    let progress: Progress
    let asset: PhotoAsset
    let handler: (ImageCaptureTransferProgress) -> Void
    var pollingTask: Task<Void, Never>?
}

/// Protects the completion continuation because ImageCaptureCore may complete
/// on a non-main queue and cancellation can race with that callback.
private final class DownloadContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Error>?
    private var progress: Progress?
    private var finished = false
    private var cancelled = false

    func install(_ continuation: CheckedContinuation<String?, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func attach(_ progress: Progress) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        self.progress = progress
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { progress.cancel() }
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let progress = progress
        lock.unlock()
        progress?.cancel()
    }

    @discardableResult
    func finish(path: String?, error: Error?) -> Bool {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return false
        }
        finished = true
        self.continuation = nil
        self.progress = nil
        let cancelled = cancelled
        lock.unlock()

        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: path)
        }
        return true
    }
}
