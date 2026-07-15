import Foundation
@preconcurrency import Network

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }

    func resume(_ result: Result<Void, Error>) {
        let pending = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        switch result {
        case .success: pending.resume()
        case .failure(let error): pending.resume(throwing: error)
        }
    }
}

private final class PTPChannel: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.huiliyi.CameraBridge.ptpip.channel", qos: .userInitiated)

    init(host: String, port: UInt16) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw PTPError.invalidPacket("端口无效")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.connectionTimeout = 15
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredInterfaceType = .wifi
        parameters.prohibitExpensivePaths = false
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = ContinuationGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.resume(.success(()))
                case .failed(let error): gate.resume(.failure(error))
                case .cancelled: gate.resume(.failure(PTPError.disconnected))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func readPacket() async throws -> PTPPacket {
        let header = try await receiveExactly(8)
        var reader = PTPReader(header)
        let length = Int(try reader.u32())
        guard length >= 8, length <= PTPIPCodec.maximumPacketLength else {
            throw PTPError.invalidPacket("包长度 \(length) 超出范围")
        }
        let payload = try await receiveExactly(length - 8)
        return try PTPIPCodec.decodePacket(header: header, payload: payload)
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            let remaining = count - result.count
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: PTPError.disconnected) }
                    else { continuation.resume(throwing: PTPError.invalidPacket("读取到空数据")) }
                }
            }
            result.append(chunk)
        }
        return result
    }

    func close() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }
}

actor PTPIPClient {
    private enum PacketType {
        static let initCommandRequest: UInt32 = 1
        static let initCommandAck: UInt32 = 2
        static let initEventRequest: UInt32 = 3
        static let initEventAck: UInt32 = 4
        static let operationResponse: UInt32 = 7
        static let startData: UInt32 = 9
        static let data: UInt32 = 10
        static let endData: UInt32 = 12
    }

    private enum Operation {
        static let getDeviceInfo: UInt16 = 0x1001
        static let openSession: UInt16 = 0x1002
        static let closeSession: UInt16 = 0x1003
        static let getObjectHandles: UInt16 = 0x1007
        static let getObjectInfo: UInt16 = 0x1008
        static let getObject: UInt16 = 0x1009
        static let getThumb: UInt16 = 0x100A
        static let getDeviceProperty: UInt16 = 0x1015
        static let getPartialObject: UInt16 = 0x101B
    }

    private let host: String
    private let port: UInt16
    private var command: PTPChannel?
    private var event: PTPChannel?
    private var eventDrainTask: Task<Void, Never>?
    private var transaction: UInt32 = 1
    private var objectHandles: [UInt32]?
    private var session: CameraSession?
    private var operationLocked = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    init(host: String, port: Int) throws {
        guard let port = UInt16(exactly: port) else { throw PTPError.invalidPacket("端口无效") }
        self.host = host
        self.port = port
    }

    func connect() async throws -> CameraSession {
        await acquireOperation()
        defer { releaseOperation() }
        let value = try await connectUnlocked()
        session = value
        return value
    }

    func checkConnection() async throws {
        await acquireOperation()
        defer { releaseOperation() }
        _ = try await requestDataUnlocked(operation: Operation.getDeviceInfo, transaction: nextTransaction())
    }

    func refreshAssets() {
        objectHandles = nil
    }

    func assets(offset: Int, limit: Int) async throws -> (items: [PhotoAsset], hasMore: Bool) {
        await acquireOperation()
        defer { releaseOperation() }
        let handles: [UInt32]
        if let objectHandles { handles = objectHandles }
        else {
            let data = try await requestDataUnlocked(
                operation: Operation.getObjectHandles,
                transaction: nextTransaction(),
                parameters: [UInt32.max, 0, 0]
            )
            var reader = PTPReader(data)
            handles = Array(try reader.u32Array().reversed())
            objectHandles = handles
        }
        let start = min(max(offset, 0), handles.count)
        let page = handles.dropFirst(start).prefix(max(limit, 0))
        var items: [PhotoAsset] = []
        for handle in page {
            do {
                let data = try await requestDataUnlocked(operation: Operation.getObjectInfo, transaction: nextTransaction(), parameters: [handle])
                items.append(try parseObject(handle: handle, data: data))
            } catch {
                continue
            }
        }
        return (items, start + page.count < handles.count)
    }

    func thumbnail(for asset: PhotoAsset) async throws -> Data? {
        await acquireOperation()
        defer { releaseOperation() }
        return try? await requestDataUnlocked(operation: Operation.getThumb, transaction: nextTransaction(), parameters: [asset.handle])
    }

    func imageHeader(for asset: PhotoAsset) async throws -> Data? {
        await acquireOperation()
        defer { releaseOperation() }
        let count = UInt32(min(max(asset.size, 1), 256 * 1024))
        return try? await requestDataUnlocked(
            operation: Operation.getPartialObject,
            transaction: nextTransaction(),
            parameters: [asset.handle, 0, count]
        )
    }

    func download(
        _ asset: PhotoAsset,
        to destination: URL,
        cancellation: DownloadCancellationToken,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        await acquireOperation()
        defer { releaseOperation() }
        guard asset.size <= Int64(UInt32.max) else { throw PTPError.unsupportedLargeObject }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close() }
        try file.truncate(atOffset: 0)

        if asset.size > 0, asset.size <= 16 * 1024 * 1024 {
            do {
                _ = try await requestToFileUnlocked(
                    operation: Operation.getObject,
                    transaction: nextTransaction(),
                    parameters: [asset.handle],
                    file: file,
                    baseOffset: 0,
                    total: asset.size,
                    cancellation: cancellation,
                    progress: progress
                )
                return
            } catch PTPError.cancelled {
                throw PTPError.cancelled
            } catch {
                try file.truncate(atOffset: 0)
                try file.seek(toOffset: 0)
                try await reconnectUnlocked()
            }
        }

        var controller = AdaptiveChunkController()
        var offset: Int64 = 0
        var retries = 0
        while offset < asset.size {
            if cancellation.isCancelled { throw PTPError.cancelled }
            let count = controller.requestLength(remaining: asset.size - offset)
            do {
                try file.seek(toOffset: UInt64(offset))
                let written = try await requestToFileUnlocked(
                    operation: Operation.getPartialObject,
                    transaction: nextTransaction(),
                    parameters: [asset.handle, UInt32(offset), UInt32(count)],
                    file: file,
                    baseOffset: offset,
                    total: asset.size,
                    cancellation: cancellation,
                    progress: progress
                )
                guard written > 0 else { throw PTPError.emptyChunk }
                offset += written
                controller.registerSuccess()
                retries = 0
            } catch PTPError.cancelled {
                throw PTPError.cancelled
            } catch {
                try file.truncate(atOffset: UInt64(offset))
                retries += 1
                guard retries <= 5 else { throw error }
                controller.registerFailure()
                if String(describing: error).localizedCaseInsensitiveContains("busy") {
                    try await Task.sleep(for: .milliseconds(50 * retries))
                } else {
                    try await reconnectUnlocked()
                }
            }
        }
    }

    func disconnect() async {
        await acquireOperation()
        defer { releaseOperation() }
        if command != nil {
            try? await requestResponseUnlocked(operation: Operation.closeSession, transaction: nextTransaction())
        }
        closeChannels()
        session = nil
        objectHandles = nil
    }

    private func connectUnlocked() async throws -> CameraSession {
        closeChannels()
        let command = try PTPChannel(host: host, port: port)
        try await command.open()
        self.command = command

        var commandPayload = Data([
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF
        ])
        commandPayload.append(PTPIPCodec.utf16z("Android Device"))
        commandPayload.appendLE(UInt32(0x0001_0000))
        try await command.send(PTPIPCodec.packet(type: PacketType.initCommandRequest, payload: commandPayload))
        let acknowledgement = try await command.readPacket()
        guard acknowledgement.type == PacketType.initCommandAck else {
            throw PTPError.invalidPacket("相机拒绝了命令通道")
        }
        var acknowledgementReader = PTPReader(acknowledgement.payload)
        let connectionNumber = try acknowledgementReader.u32()
        _ = try acknowledgementReader.bytes(16)
        let connectionName = try acknowledgementReader.nullTerminatedUTF16()
        let version = try acknowledgementReader.u32()
        guard version >> 16 == 1 else { throw PTPError.invalidPacket("不支持的协议版本") }

        let event = try PTPChannel(host: host, port: port)
        try await event.open()
        var eventPayload = Data()
        eventPayload.appendLE(connectionNumber)
        try await event.send(PTPIPCodec.packet(type: PacketType.initEventRequest, payload: eventPayload))
        let eventAcknowledgement = try await event.readPacket()
        guard eventAcknowledgement.type == PacketType.initEventAck else {
            throw PTPError.invalidPacket("相机拒绝了事件通道")
        }
        self.event = event
        eventDrainTask = Task.detached(priority: .utility) { [weak event] in
            guard let event else { return }
            while !Task.isCancelled { _ = try? await event.readPacket() }
        }

        let deviceInfo = try await requestDataUnlocked(operation: Operation.getDeviceInfo, transaction: 0)
        let parsed = try parseDeviceInfo(deviceInfo)
        try await requestResponseUnlocked(operation: Operation.openSession, transaction: 0, parameters: [1])
        transaction = 1
        let liveDetails = await readLiveCameraDetails(parsed.details, supportedProperties: parsed.supportedProperties)
        let displayName = liveDetails.model?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? connectionName.nilIfEmpty
            ?? "Nikon 相机"
        return CameraSession(name: displayName, host: host, port: Int(port), transport: .wifi, details: liveDetails)
    }

    private func reconnectUnlocked() async throws {
        let cachedHandles = objectHandles
        let value = try await connectUnlocked()
        session = value
        objectHandles = cachedHandles
    }

    private func requestResponseUnlocked(operation: UInt16, transaction: UInt32, parameters: [UInt32] = []) async throws {
        guard let command else { throw PTPError.disconnected }
        try await command.send(PTPIPCodec.operation(operation: operation, transaction: transaction, parameters: parameters))
        let packet = try await command.readPacket()
        guard packet.type == PacketType.operationResponse else { throw PTPError.unexpectedPacket(packet.type) }
        var reader = PTPReader(packet.payload)
        let response = try reader.u16()
        guard response == 0x2001 else { throw PTPError.rejected(operation: operation, response: response) }
    }

    private func requestDataUnlocked(operation: UInt16, transaction: UInt32, parameters: [UInt32] = []) async throws -> Data {
        guard let command else { throw PTPError.disconnected }
        try await command.send(PTPIPCodec.operation(operation: operation, transaction: transaction, parameters: parameters))
        var output = Data()
        while true {
            let packet = try await command.readPacket()
            switch packet.type {
            case PacketType.startData:
                break
            case PacketType.data, PacketType.endData:
                var reader = PTPReader(packet.payload)
                _ = try reader.u32()
                output.append(try reader.remaining())
            case PacketType.operationResponse:
                var reader = PTPReader(packet.payload)
                let response = try reader.u16()
                guard response == 0x2001 else { throw PTPError.rejected(operation: operation, response: response) }
                return output
            default:
                throw PTPError.unexpectedPacket(packet.type)
            }
        }
    }

    private func requestToFileUnlocked(
        operation: UInt16,
        transaction: UInt32,
        parameters: [UInt32],
        file: FileHandle,
        baseOffset: Int64,
        total: Int64,
        cancellation: DownloadCancellationToken,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> Int64 {
        guard let command else { throw PTPError.disconnected }
        try await command.send(PTPIPCodec.operation(operation: operation, transaction: transaction, parameters: parameters))
        var written: Int64 = 0
        var draining = cancellation.isCancelled
        while true {
            let packet = try await command.readPacket()
            switch packet.type {
            case PacketType.startData:
                if cancellation.isCancelled { draining = true }
                if !draining { progress(baseOffset, total) }
            case PacketType.data, PacketType.endData:
                var reader = PTPReader(packet.payload)
                _ = try reader.u32()
                let part = try reader.remaining()
                if cancellation.isCancelled { draining = true }
                if !draining {
                    try file.write(contentsOf: part)
                    written += Int64(part.count)
                    progress(baseOffset + written, total)
                }
            case PacketType.operationResponse:
                var reader = PTPReader(packet.payload)
                let response = try reader.u16()
                guard response == 0x2001 else { throw PTPError.rejected(operation: operation, response: response) }
                if draining || cancellation.isCancelled { throw PTPError.cancelled }
                return written
            default:
                throw PTPError.unexpectedPacket(packet.type)
            }
        }
    }

    private func parseObject(handle: UInt32, data: Data) throws -> PhotoAsset {
        var reader = PTPReader(data)
        _ = try reader.u32()
        let format = try reader.u16()
        _ = try reader.u16()
        let size = try reader.u32()
        _ = try reader.u16()
        for _ in 0 ..< 7 { _ = try reader.u32() }
        _ = try reader.u16()
        _ = try reader.u32()
        _ = try reader.u32()
        let name = try reader.ptpString().nilIfEmpty ?? "IMG_\(handle)"
        let capturedAt = Self.parsePTPDate(try reader.ptpString())
        return PhotoAsset(handle: handle, name: name, size: Int64(size), format: format, capturedAt: capturedAt)
    }

    private func parseDeviceInfo(_ data: Data) throws -> (details: CameraDetails, supportedProperties: Set<UInt16>) {
        var reader = PTPReader(data)
        _ = try reader.u16()
        _ = try reader.u32()
        _ = try reader.u16()
        _ = try reader.ptpString()
        _ = try reader.u16()
        _ = try reader.u16Array()
        _ = try reader.u16Array()
        let supportedProperties = Set(try reader.u16Array())
        _ = try reader.u16Array()
        _ = try reader.u16Array()
        let details = CameraDetails(
            manufacturer: try reader.ptpString().nilIfEmpty,
            model: try reader.ptpString().nilIfEmpty,
            deviceVersion: try reader.ptpString().nilIfEmpty,
            serialNumber: try reader.ptpString().nilIfEmpty
        )
        return (details, supportedProperties)
    }

    private func readLiveCameraDetails(_ details: CameraDetails, supportedProperties: Set<UInt16>) async -> CameraDetails {
        func readProperty(_ code: UInt16) async -> UInt64? {
            guard supportedProperties.contains(code) else { return nil }
            guard let bytes = try? await requestDataUnlocked(operation: Operation.getDeviceProperty, transaction: nextTransaction(), parameters: [UInt32(code)]) else { return nil }
            var reader = PTPReader(bytes)
            switch bytes.count {
            case 1: return (try? reader.u8()).map(UInt64.init)
            case 2: return (try? reader.u16()).map(UInt64.init)
            case 4: return (try? reader.u32()).map(UInt64.init)
            case 8: return try? reader.u64()
            default: return nil
            }
        }
        let battery = await readProperty(0x5001)
        let minimumFocal = await readProperty(0xD0E3)
        let maximumFocal = await readProperty(0xD0E4)
        let minimumAperture = await readProperty(0xD0E5)
        let maximumAperture = await readProperty(0xD0E6)
        let focal = Self.rangeText(minimumFocal, maximumFocal, prefix: "", suffix: "mm")
        let aperture = Self.rangeText(minimumAperture, maximumAperture, prefix: "f/", suffix: "")
        var updated = details
        updated.batteryPercent = battery.flatMap { Int($0) }.flatMap { (0 ... 100).contains($0) ? $0 : nil }
        updated.lensSpecification = [focal, aperture].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        return updated
    }

    private func nextTransaction() -> UInt32 {
        defer { transaction &+= 1 }
        return transaction
    }

    private func acquireOperation() async {
        if !operationLocked {
            operationLocked = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func releaseOperation() {
        if operationWaiters.isEmpty { operationLocked = false }
        else { operationWaiters.removeFirst().resume() }
    }

    private func closeChannels() {
        eventDrainTask?.cancel()
        eventDrainTask = nil
        command?.close()
        event?.close()
        command = nil
        event = nil
    }

    private static func parsePTPDate(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.date(from: String(value.prefix(15))) ?? .now
    }

    private static func rangeText(_ minimum: UInt64?, _ maximum: UInt64?, prefix: String, suffix: String) -> String? {
        guard minimum != nil || maximum != nil else { return nil }
        func value(_ input: UInt64) -> String {
            let scaled = Double(input) / 100
            return scaled.rounded() == scaled ? String(Int(scaled)) : String(format: "%.1f", scaled)
        }
        if let minimum, let maximum, minimum != maximum {
            return "\(prefix)\(value(minimum))–\(value(maximum))\(suffix)"
        }
        return "\(prefix)\(value(minimum ?? maximum!))\(suffix)"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
