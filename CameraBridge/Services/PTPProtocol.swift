import Foundation

enum PTPError: LocalizedError, Equatable {
    case disconnected
    case invalidPacket(String)
    case rejected(operation: UInt16, response: UInt16)
    case unexpectedPacket(UInt32)
    case cancelled
    case unsupportedLargeObject
    case emptyChunk

    var errorDescription: String? {
        switch self {
        case .disconnected: "相机已断开连接"
        case .invalidPacket(let message): "PTP/IP 数据无效：\(message)"
        case .rejected(let operation, let response): String(format: "相机拒绝请求 0x%04X（响应 0x%04X）", operation, response)
        case .unexpectedPacket(let type): "收到意外的 PTP/IP 数据包：\(type)"
        case .cancelled: "下载已取消"
        case .unsupportedLargeObject: "标准 PTP/IP 无法分段传输超过 4 GiB 的文件"
        case .emptyChunk: "相机返回了空的数据分块"
        }
    }
}

struct PTPPacket: Equatable {
    let type: UInt32
    let payload: Data
}

struct PTPReader {
    private let data: Data
    private(set) var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw PTPError.invalidPacket("数据被截断")
        }
        defer { offset += count }
        return data.subdata(in: offset ..< offset + count)
    }

    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func u16() throws -> UInt16 {
        let value = try bytes(2)
        return UInt16(value[0]) | UInt16(value[1]) << 8
    }
    mutating func u32() throws -> UInt32 {
        let value = try bytes(4)
        return UInt32(value[0]) | UInt32(value[1]) << 8 | UInt32(value[2]) << 16 | UInt32(value[3]) << 24
    }
    mutating func u64() throws -> UInt64 {
        let low = UInt64(try u32())
        return low | UInt64(try u32()) << 32
    }
    mutating func remaining() throws -> Data { try bytes(data.count - offset) }
    mutating func u16Array() throws -> [UInt16] {
        let count = Int(try u32())
        guard count <= 65_536 else { throw PTPError.invalidPacket("数组过长") }
        return try (0 ..< count).map { _ in try u16() }
    }
    mutating func u32Array() throws -> [UInt32] {
        let count = Int(try u32())
        guard count <= 2_000_000 else { throw PTPError.invalidPacket("对象数量异常") }
        return try (0 ..< count).map { _ in try u32() }
    }
    mutating func ptpString() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        let text = try bytes(max(0, count * 2 - 2))
        _ = try bytes(2)
        return String(data: text, encoding: .utf16LittleEndian) ?? ""
    }
    mutating func nullTerminatedUTF16() throws -> String {
        let start = offset
        while offset + 1 < data.count {
            if data[offset] == 0, data[offset + 1] == 0 {
                let value = data.subdata(in: start ..< offset)
                offset += 2
                return String(data: value, encoding: .utf16LittleEndian) ?? ""
            }
            offset += 2
        }
        throw PTPError.invalidPacket("UTF-16 字符串缺少终止符")
    }
}

enum PTPIPCodec {
    static let maximumPacketLength = 128 * 1024 * 1024

    static func packet(type: UInt32, payload: Data = Data()) -> Data {
        var data = Data()
        data.appendLE(UInt32(payload.count + 8))
        data.appendLE(type)
        data.append(payload)
        return data
    }

    static func operation(operation: UInt16, transaction: UInt32, parameters: [UInt32]) -> Data {
        var payload = Data()
        payload.appendLE(UInt32(1))
        payload.appendLE(operation)
        payload.appendLE(transaction)
        parameters.prefix(5).forEach { payload.appendLE($0) }
        return packet(type: 6, payload: payload)
    }

    static func utf16z(_ value: String) -> Data {
        var data = value.data(using: .utf16LittleEndian) ?? Data()
        data.append(contentsOf: [0, 0])
        return data
    }

    static func decodePacket(header: Data, payload: Data) throws -> PTPPacket {
        var reader = PTPReader(header)
        let length = Int(try reader.u32())
        let type = try reader.u32()
        guard length >= 8, length <= maximumPacketLength, length == payload.count + 8 else {
            throw PTPError.invalidPacket("包长度不正确")
        }
        return PTPPacket(type: type, payload: payload)
    }
}

struct AdaptiveChunkController: Equatable {
    private(set) var current: Int
    let minimum: Int
    let maximum: Int
    let stableThreshold: Int
    private(set) var consecutiveStable = 0

    init(initial: Int = 4 * 1024 * 1024, minimum: Int = 1024 * 1024, maximum: Int = 8 * 1024 * 1024, stableThreshold: Int = 2) {
        self.minimum = minimum
        self.maximum = maximum
        self.stableThreshold = stableThreshold
        current = min(max(initial, minimum), maximum)
    }

    mutating func requestLength(remaining: Int64) -> Int {
        Int(min(Int64(current), max(remaining, 1)))
    }

    mutating func registerSuccess() {
        consecutiveStable += 1
        if consecutiveStable >= stableThreshold, current < maximum {
            consecutiveStable = 0
            current = min(current * 2, maximum)
        }
    }

    mutating func registerFailure() {
        consecutiveStable = 0
        current = max(current / 2, minimum)
    }
}

final class DownloadCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendLE(_ value: UInt64) {
        appendLE(UInt32(truncatingIfNeeded: value))
        appendLE(UInt32(truncatingIfNeeded: value >> 32))
    }
}
