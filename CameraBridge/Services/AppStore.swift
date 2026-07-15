import Foundation

final class AppStore {
    private enum Key {
        static let config = "camera_bridge.config.v2"
        static let downloads = "camera_bridge.downloads.v2"
        static let luts = "camera_bridge.luts.v2"
        static let watermarks = "camera_bridge.watermarks.v2"
        static let lights = "camera_bridge.lights.v2"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadConfig() -> CameraConfig { load(CameraConfig.self, key: Key.config) ?? CameraConfig() }
    func save(config: CameraConfig) { save(config, key: Key.config) }

    func loadDownloads() -> [DownloadRecord] { load([DownloadRecord].self, key: Key.downloads) ?? [] }
    func save(downloads: [DownloadRecord]) { save(downloads, key: Key.downloads) }

    func loadLUTs() -> [LUTEntry] { load([LUTEntry].self, key: Key.luts) ?? [] }
    func save(luts: [LUTEntry]) { save(luts, key: Key.luts) }

    func loadWatermarks() -> [WatermarkPreset] {
        load([WatermarkPreset].self, key: Key.watermarks) ?? WatermarkPreset.defaults
    }
    func save(watermarks: [WatermarkPreset]) { save(watermarks, key: Key.watermarks) }

    func loadLightScenes() -> [LightScene] {
        load([LightScene].self, key: Key.lights) ?? [
            LightScene(name: "单色全屏", layout: .single),
            LightScene(name: "左右双色", layout: .leftRight, zones: [
                LightZone(colorARGB: 0xFFFFC08A, intensity: 1, softness: 0.2),
                LightZone(colorARGB: 0xFF7AB8FF, intensity: 1, softness: 0.2)
            ]),
            LightScene(name: "四区光场", layout: .four)
        ]
    }
    func save(lightScenes: [LightScene]) { save(lightScenes, key: Key.lights) }

    var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var downloadsDirectory: URL {
        directory(named: "CameraBridge")
    }

    var lutDirectory: URL {
        directory(named: "LUTs", under: .applicationSupportDirectory)
    }

    var diagnosticsDirectory: URL {
        directory(named: "Diagnostics", under: .cachesDirectory)
    }

    func url(for record: DownloadRecord) -> URL {
        downloadsDirectory.appendingPathComponent(record.relativePath)
    }

    func uniqueDownloadURL(named requestedName: String) -> URL {
        uniqueURL(in: downloadsDirectory, named: requestedName)
    }

    func uniqueLUTURL(named requestedName: String) -> URL {
        uniqueURL(in: lutDirectory, named: requestedName)
    }

    func pruneMissingDownloads(_ records: [DownloadRecord]) -> [DownloadRecord] {
        records.filter { FileManager.default.fileExists(atPath: url(for: $0).path) }
    }

    private func directory(named name: String, under searchPath: FileManager.SearchPathDirectory? = nil) -> URL {
        let base = searchPath.map { FileManager.default.urls(for: $0, in: .userDomainMask)[0] } ?? documentsDirectory
        let url = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func uniqueURL(in directory: URL, named requestedName: String) -> URL {
        let safeName = requestedName.replacingOccurrences(of: "/", with: "_")
        let requested = directory.appendingPathComponent(safeName)
        guard FileManager.default.fileExists(atPath: requested.path) else { return requested }
        let extensionName = requested.pathExtension
        let stem = requested.deletingPathExtension().lastPathComponent
        var index = 1
        while true {
            let candidateName = extensionName.isEmpty
                ? String(format: "%@_%02d", stem, index)
                : String(format: "%@_%02d.%@", stem, index, extensionName)
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
