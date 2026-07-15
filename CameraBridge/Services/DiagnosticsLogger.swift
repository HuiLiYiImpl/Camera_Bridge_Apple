import Foundation
import UIKit

actor DiagnosticsLogger {
    struct Event: Codable {
        var timestamp: Date
        var level: String
        var name: String
        var phase: String
        var transport: String?
        var message: String
        var error: String?
        var metadata: [String: String]
    }

    private var events: [Event] = []
    private let maximumEvents = 500

    func log(
        _ name: String,
        phase: String,
        level: String = "INFO",
        transport: CameraTransport? = nil,
        message: String = "",
        error: Error? = nil,
        metadata: [String: String] = [:]
    ) {
        events.append(Event(
            timestamp: .now,
            level: level,
            name: name,
            phase: phase,
            transport: transport?.rawValue.uppercased(),
            message: message,
            error: error.map { String(describing: $0) },
            metadata: metadata
        ))
        if events.count > maximumEvents { events.removeFirst(events.count - maximumEvents) }
    }

    func clear() { events.removeAll() }

    func text() -> String {
        events.map { event in
            let fields = event.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            return "[\(event.timestamp.ISO8601Format())] [\(event.level)] \(event.name) phase=\(event.phase) \(event.message) \(fields) \(event.error ?? "")"
        }.joined(separator: "\n")
    }

    func export(into directory: URL, session: CameraSession?, config: CameraConfig) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = directory.appendingPathComponent("CameraBridge-Diagnostics-\(formatter.string(from: .now)).json")
        let snapshot = ExportSnapshot(
            generatedAt: .now,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            system: UIDevice.current.systemName + " " + UIDevice.current.systemVersion,
            device: UIDevice.current.model,
            configuredHost: "\(config.host):\(config.port)",
            session: session,
            events: events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: target, options: .atomic)
        return target
    }

    private struct ExportSnapshot: Codable {
        var generatedAt: Date
        var appVersion: String
        var system: String
        var device: String
        var configuredHost: String
        var session: CameraSession?
        var events: [Event]
    }
}
