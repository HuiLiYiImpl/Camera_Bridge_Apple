import Foundation
import SwiftUI
import UIKit

enum CameraTransport: String, Codable, CaseIterable, Identifiable {
    case wifi
    case usb

    var id: Self { self }
    var title: String { self == .wifi ? "Wi-Fi" : "USB" }
    var symbol: String { self == .wifi ? "wifi" : "cable.connector" }
}

enum CameraBrand: String, Codable, CaseIterable, Identifiable {
    case nikon, canon, sony, panasonic, fujifilm, other

    var id: Self { self }
    var title: String {
        switch self {
        case .nikon: "尼康"
        case .canon: "佳能"
        case .sony: "索尼"
        case .panasonic: "松下"
        case .fujifilm: "富士"
        case .other: "其他品牌"
        }
    }
    var available: Bool { self == .nikon }
}

enum AppColorTheme: String, Codable, CaseIterable, Identifiable {
    case darkroomOrange, nikonYellow, professionalGray, deepBlue

    var id: Self { self }
    var title: String {
        switch self {
        case .darkroomOrange: "暗房橙"
        case .nikonYellow: "尼康黄"
        case .professionalGray: "专业灰"
        case .deepBlue: "深海蓝"
        }
    }
    var subtitle: String {
        switch self {
        case .darkroomOrange: "暖调胶片"
        case .nikonYellow: "经典醒目"
        case .professionalGray: "中性克制"
        case .deepBlue: "现代科技"
        }
    }
}

struct CameraConfig: Codable, Equatable {
    var host = "192.168.1.1"
    var port = 15_740
    var autoExport = true
    var lastCameraName = ""
    var lastTransport: CameraTransport = .wifi
    var keepWiFiAlive = true
    var jpegQuality = 95
    var fileNamingRule = "原文件名_编辑类型"
    var thumbnailCacheEnabled = true
    var colorTheme: AppColorTheme = .darkroomOrange
    var brand: CameraBrand = .nikon
}

struct CameraDetails: Codable, Equatable {
    var manufacturer: String?
    var model: String?
    var deviceVersion: String?
    var serialNumber: String?
    var batteryPercent: Int?
    var lensName: String?
    var lensSpecification: String?
    var recentFocalLength: String?
    var recentAperture: String?
    var recentShutter: String?
    var recentISO: Int?
    var recentCapturedAt: Date?
}

struct CameraSession: Codable, Equatable {
    var name: String
    var host: String
    var port: Int
    var transport: CameraTransport
    var details: CameraDetails
}

enum Workflow: Equatable {
    case waiting
    case connecting
    case connected
    case loading
    case downloading
    case error(String)

    var busy: Bool {
        switch self {
        case .connecting, .loading, .downloading: true
        default: false
        }
    }
}

enum MediaKind: String, Codable, CaseIterable, Identifiable {
    case image, rawImage, video, unknown
    var id: Self { self }
    var title: String {
        switch self {
        case .image: "JPG"
        case .rawImage: "RAW"
        case .video: "视频"
        case .unknown: "文件"
        }
    }

    static func infer(name: String, format: UInt16? = nil) -> MediaKind {
        if let format {
            switch format {
            case 0x3801, 0x3808, 0x380B: return .image
            case 0x3000, 0x3004: return .rawImage
            case 0x300C, 0x380D: return .video
            default: break
            }
        }
        switch name.split(separator: ".").last?.lowercased() {
        case "jpg", "jpeg", "png", "heic", "heif", "webp": return .image
        case "nef", "nrw", "cr2", "arw", "dng", "raf": return .rawImage
        case "mov", "mp4", "m4v", "3gp": return .video
        default: return .unknown
        }
    }
}

struct PhotoAsset: Identifiable, Hashable, Codable {
    let handle: UInt32
    let name: String
    let size: Int64
    let format: UInt16
    let capturedAt: Date

    var id: UInt32 { handle }
    var kind: MediaKind { .infer(name: name, format: format) }
    var typeLabel: String { kind.title }
}

enum MediaFilter: String, CaseIterable, Identifiable {
    case all, jpg, raw, video
    var id: Self { self }
    var title: String {
        switch self {
        case .all: "全部"
        case .jpg: "JPG"
        case .raw: "RAW"
        case .video: "视频"
        }
    }
    func matches(_ kind: MediaKind) -> Bool {
        switch self {
        case .all: true
        case .jpg: kind == .image
        case .raw: kind == .rawImage
        case .video: kind == .video
        }
    }
}

struct DownloadRecord: Identifiable, Hashable, Codable {
    var id: UUID
    var name: String
    var size: Int64
    var relativePath: String
    var completedAt: Date
    var kind: MediaKind
    var edited: Bool

    init(
        id: UUID = UUID(),
        name: String,
        size: Int64,
        relativePath: String,
        completedAt: Date = .now,
        kind: MediaKind? = nil,
        edited: Bool = false
    ) {
        self.id = id
        self.name = name
        self.size = size
        self.relativePath = relativePath
        self.completedAt = completedAt
        self.kind = kind ?? .infer(name: name)
        self.edited = edited
    }
}

enum DownloadTaskStatus: String, Codable {
    case queued, downloading, cancelling, failed
}

struct DownloadTaskModel: Identifiable, Codable, Equatable {
    let id: String
    let asset: PhotoAsset
    var downloadedBytes: Int64 = 0
    var totalBytes: Int64
    var bytesPerSecond: Int64?
    var remainingSeconds: Int?
    var status: DownloadTaskStatus = .queued
    var createdAt = Date()
    var errorMessage: String?

    init(asset: PhotoAsset, sessionName: String) {
        id = "\(sessionName)|\(asset.handle)|\(asset.name)|\(asset.size)"
        self.asset = asset
        totalBytes = max(asset.size, 0)
    }

    var progress: Double {
        totalBytes > 0 ? min(max(Double(downloadedBytes) / Double(totalBytes), 0), 1) : 0
    }
}

enum LUTCategory: String, Codable, CaseIterable, Identifiable {
    case portrait, film, cinema, landscape, other
    var id: Self { self }
    var title: String {
        switch self {
        case .portrait: "人像"
        case .film: "胶片"
        case .cinema: "电影"
        case .landscape: "风光"
        case .other: "未分类"
        }
    }
}

struct LUTEntry: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var category: LUTCategory
    var format: String
    var dimension: Int
    var sourceName: String
    var storedFileName: String
    var favorite: Bool
    var lastUsedAt: Date?
    var importedAt: Date

    init(
        id: UUID = UUID(), name: String, category: LUTCategory = .other,
        format: String, dimension: Int, sourceName: String, storedFileName: String,
        favorite: Bool = false, lastUsedAt: Date? = nil, importedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.format = format
        self.dimension = dimension
        self.sourceName = sourceName
        self.storedFileName = storedFileName
        self.favorite = favorite
        self.lastUsedAt = lastUsedAt
        self.importedAt = importedAt
    }
}

struct CubeLUT: Equatable {
    let name: String
    let size: Int
    let values: [Float]
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
}

enum WatermarkLayout: String, Codable, CaseIterable, Identifiable {
    case atmosphere, leftParameters, rightParameters, whiteBorder, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .atmosphere: "氛围模糊背景"
        case .leftParameters: "底部信息条（Logo 左）"
        case .rightParameters: "底部信息条（Logo 右）"
        case .whiteBorder: "正方形白边框"
        case .custom: "仅自定义文字"
        }
    }
}

enum WatermarkField: String, Codable, CaseIterable, Identifiable {
    case cameraBrand, cameraModel, lensModel, iso, shutter, aperture, focalLength
    case equivalentFocalLength, captureDate, customText, copyright
    var id: Self { self }
    var title: String {
        switch self {
        case .cameraBrand: "相机品牌"
        case .cameraModel: "相机型号"
        case .lensModel: "镜头型号"
        case .iso: "ISO"
        case .shutter: "快门速度"
        case .aperture: "光圈"
        case .focalLength: "焦距"
        case .equivalentFocalLength: "等效焦距"
        case .captureDate: "拍摄日期"
        case .customText: "自定义文字"
        case .copyright: "版权文字"
        }
    }
}

struct WatermarkPreset: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var layout: WatermarkLayout
    var fields: Set<WatermarkField>
    var fontSize: Double
    var textColor: UInt32
    var backgroundColor: UInt32
    var backgroundAlpha: Double
    var margin: Double
    var showBorder: Bool
    var frameEnabled: Bool
    var frameThickness: Double
    var customText: String
    var copyrightText: String
    var logoEnabled: Bool
    var useBrandLogo: Bool
    var logoName: String?
    var logoScale: Double
    var logoAlpha: Double
    var logoOnRight: Bool
    var quality: Double

    static let defaults: [WatermarkPreset] = [
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "氛围模糊背景", layout: .atmosphere, fields: [.cameraBrand, .cameraModel, .focalLength, .aperture, .shutter, .iso], fontSize: 34, textColor: 0xFFFFFFFF, backgroundColor: 0xFF000000, backgroundAlpha: 0.82, margin: 28, showBorder: false, frameEnabled: false, frameThickness: 24, customText: "", copyrightText: "", logoEnabled: false, useBrandLogo: false, logoName: nil, logoScale: 1, logoAlpha: 1, logoOnRight: true, quality: 0.95),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "底部信息条（Logo 右）", layout: .rightParameters, fields: Set(WatermarkField.allCases.filter { ![.customText, .copyright].contains($0) }), fontSize: 34, textColor: 0xFF000000, backgroundColor: 0xFFFFFFFF, backgroundAlpha: 1, margin: 28, showBorder: false, frameEnabled: false, frameThickness: 24, customText: "", copyrightText: "", logoEnabled: true, useBrandLogo: true, logoName: nil, logoScale: 1, logoAlpha: 1, logoOnRight: true, quality: 0.95),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, name: "底部信息条（Logo 左）", layout: .leftParameters, fields: Set(WatermarkField.allCases.filter { ![.customText, .copyright].contains($0) }), fontSize: 34, textColor: 0xFF000000, backgroundColor: 0xFFFFFFFF, backgroundAlpha: 1, margin: 28, showBorder: false, frameEnabled: true, frameThickness: 24, customText: "", copyrightText: "", logoEnabled: true, useBrandLogo: true, logoName: nil, logoScale: 1, logoAlpha: 1, logoOnRight: false, quality: 0.95),
        .init(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "正方形白边框", layout: .whiteBorder, fields: [], fontSize: 34, textColor: 0xFF000000, backgroundColor: 0xFFFFFFFF, backgroundAlpha: 1, margin: 28, showBorder: false, frameEnabled: false, frameThickness: 24, customText: "", copyrightText: "", logoEnabled: false, useBrandLogo: false, logoName: nil, logoScale: 1, logoAlpha: 1, logoOnRight: true, quality: 0.95)
    ]
}

struct PhotoMetadata: Equatable {
    var cameraBrand: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var shutterSpeed: String?
    var aperture: String?
    var focalLength: String?
    var equivalentFocalLength: String?
    var capturedAt: Date?
    var customText: String?
    var copyrightText: String?
}

enum LightLayout: String, Codable, CaseIterable, Identifiable {
    case single, leftRight, topBottom, four
    var id: Self { self }
    var title: String {
        switch self {
        case .single: "单色全屏"
        case .leftRight: "左右双色"
        case .topBottom: "上下双色"
        case .four: "四区光场"
        }
    }
    var zoneCount: Int {
        switch self { case .single: 1; case .leftRight, .topBottom: 2; case .four: 4 }
    }
}

struct LightZone: Identifiable, Codable, Hashable {
    var id = UUID()
    var colorARGB: UInt32 = 0xFFFFFFFF
    var intensity: Double = 1
    var softness: Double = 0.12
}

struct LightScene: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var layout: LightLayout
    var zones: [LightZone]
    var screenBrightness: Double

    init(id: UUID = UUID(), name: String, layout: LightLayout, zones: [LightZone]? = nil, screenBrightness: Double = 1) {
        self.id = id
        self.name = name
        self.layout = layout
        self.zones = zones ?? Array(repeating: LightZone(), count: layout.zoneCount)
        self.screenBrightness = screenBrightness
    }
}

extension UInt32 {
    var color: Color {
        Color(
            red: Double((self >> 16) & 0xFF) / 255,
            green: Double((self >> 8) & 0xFF) / 255,
            blue: Double(self & 0xFF) / 255,
            opacity: Double((self >> 24) & 0xFF) / 255
        )
    }
}

extension Color {
    var argb: UInt32 {
        let components = UIColor(self).cgColor.components ?? [0, 0, 0, 1]
        let red = components.count >= 3 ? components[0] : components[0]
        let green = components.count >= 3 ? components[1] : components[0]
        let blue = components.count >= 3 ? components[2] : components[0]
        let alpha = components.count >= 4 ? components[3] : (components.count == 2 ? components[1] : 1)
        return UInt32(alpha * 255) << 24 | UInt32(red * 255) << 16 | UInt32(green * 255) << 8 | UInt32(blue * 255)
    }
}

extension Int64 {
    var byteCountText: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Date {
    var bridgeDateText: String {
        formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
    }
}
