import CoreImage
import Foundation
import ImageIO
import SwiftUI
import UIKit

enum MediaProcessingError: LocalizedError {
    case cannotDecodeImage
    case cannotWriteImage
    case photoLibraryDenied
    case videoExportFailed(String)
    case insufficientStorage(required: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .cannotDecodeImage: "无法解码图片"
        case .cannotWriteImage: "无法写入图片"
        case .photoLibraryDenied: "未获得系统照片图库写入权限"
        case .videoExportFailed(let message): "视频导出失败：\(message)"
        case .insufficientStorage(let required, let available):
            "存储空间不足：导出约需 \(required.byteCountText)，当前可用 \(available.byteCountText)"
        }
    }
}

enum PhotoMetadataReader {
    static func read(from data: Data, fallback: PhotoMetadata = PhotoMetadata()) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return fallback }
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let make = clean(tiff[kCGImagePropertyTIFFMake as String] as? String)
        let model = clean(tiff[kCGImagePropertyTIFFModel as String] as? String)
        let lens = clean(exif[kCGImagePropertyExifLensModel as String] as? String)
        let isoValues = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int]
        let exposure = (exif[kCGImagePropertyExifExposureTime as String] as? NSNumber)?.doubleValue
        let aperture = (exif[kCGImagePropertyExifFNumber as String] as? NSNumber)?.doubleValue
        let focal = (exif[kCGImagePropertyExifFocalLength as String] as? NSNumber)?.doubleValue
        let equivalent = (exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? NSNumber)?.intValue
        let dateText = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
            ?? tiff[kCGImagePropertyTIFFDateTime as String] as? String
        return PhotoMetadata(
            cameraBrand: make ?? fallback.cameraBrand,
            cameraModel: model ?? fallback.cameraModel,
            lensModel: lens ?? fallback.lensModel,
            iso: isoValues?.first ?? fallback.iso,
            shutterSpeed: exposure.map(formatExposure) ?? fallback.shutterSpeed,
            aperture: aperture.map { String(format: "f/%.1f", $0) } ?? fallback.aperture,
            focalLength: focal.map { "\(Int($0.rounded()))mm" } ?? fallback.focalLength,
            equivalentFocalLength: equivalent.map { "\($0)mm" } ?? fallback.equivalentFocalLength,
            capturedAt: dateText.flatMap(parseEXIFDate) ?? fallback.capturedAt,
            customText: fallback.customText,
            copyrightText: clean(tiff[kCGImagePropertyTIFFCopyright as String] as? String) ?? fallback.copyrightText
        )
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.lowercased() != "unknown", trimmed != "0" else { return nil }
        return trimmed
    }

    private static func formatExposure(_ value: Double) -> String {
        if value > 0, value < 1 { return "1/\(Int((1 / value).rounded()))s" }
        return String(format: "%.2fs", value)
    }

    private static func parseEXIFDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }
}

final class WatermarkRenderer: @unchecked Sendable {
    static let shared = WatermarkRenderer()
    private let ciContext = CIContext()

    func render(image: UIImage, metadata: PhotoMetadata, preset: WatermarkPreset) throws -> UIImage {
        guard image.size.width > 0, image.size.height > 0 else { throw MediaProcessingError.cannotDecodeImage }
        switch preset.layout {
        case .atmosphere: return atmosphere(image: image, metadata: metadata, preset: preset)
        case .leftParameters: return informationStrip(image: image, metadata: metadata, preset: preset, logoOnRight: false)
        case .rightParameters: return informationStrip(image: image, metadata: metadata, preset: preset, logoOnRight: true)
        case .whiteBorder: return squareBorder(image: image)
        case .custom: return custom(image: image, metadata: metadata, preset: preset)
        }
    }

    private func atmosphere(image: UIImage, metadata: PhotoMetadata, preset: WatermarkPreset) -> UIImage {
        let source = normalized(image)
        let rawWidth = source.size.width
        let rawHeight = max(rawWidth * 1.25, source.size.height + rawWidth * 0.28)
        let scale = min(1, 6_000 / max(rawWidth, rawHeight))
        let outputSize = CGSize(width: rawWidth * scale, height: rawHeight * scale)
        return UIGraphicsImageRenderer(size: outputSize).image { context in
            let bounds = CGRect(origin: .zero, size: outputSize)
            if let blurred = blurredFill(source, size: outputSize) {
                blurred.draw(in: bounds)
            } else {
                UIColor.black.setFill(); context.fill(bounds)
            }
            UIColor.black.withAlphaComponent(0.30).setFill(); context.fill(bounds)
            let side = outputSize.width * 0.055
            let reserved = outputSize.height * 0.19
            let imageBounds = CGRect(x: side, y: side, width: outputSize.width - side * 2, height: outputSize.height - reserved - side)
            let target = aspectFit(source.size, in: imageBounds)
            let path = UIBezierPath(roundedRect: target, cornerRadius: outputSize.width * 0.018)
            context.cgContext.saveGState(); path.addClip(); source.draw(in: target); context.cgContext.restoreGState()
            let primary = cameraLabel(metadata, preset: preset) ?? "Camera Bridge"
            let secondary = parameterLabel(metadata, preset: preset)
            drawCentered(primary, at: outputSize.height - reserved * 0.58, width: outputSize.width * 0.88, size: max(15, preset.fontSize * scale), bold: true, color: preset.textColor.color.uiColor)
            if !secondary.isEmpty {
                drawCentered(secondary, at: outputSize.height - reserved * 0.34, width: outputSize.width * 0.88, size: max(12, preset.fontSize * 0.70 * scale), bold: false, color: preset.textColor.color.uiColor.withAlphaComponent(0.78))
            }
        }
    }

    private func informationStrip(image: UIImage, metadata: PhotoMetadata, preset: WatermarkPreset, logoOnRight: Bool) -> UIImage {
        let source = normalized(image)
        let scale = source.size.width / 2_000
        let frame = preset.frameEnabled ? max(0, preset.frameThickness * scale) : 0
        let strip = max(150 * scale, source.size.width * 0.105)
        let size = CGSize(width: source.size.width + frame * 2, height: source.size.height + frame * 2 + strip)
        return UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            source.draw(at: CGPoint(x: frame, y: frame))
            let stripRect = CGRect(x: frame, y: frame + source.size.height, width: source.size.width, height: strip)
            let margin = max(30 * scale, preset.margin * scale)
            let logoWidth = preset.logoEnabled ? strip * 0.9 * preset.logoScale : 0
            let textStart = logoOnRight ? margin : margin + logoWidth
            let textEnd = logoOnRight ? stripRect.maxX - margin - logoWidth : stripRect.maxX - margin
            let primary = cameraLabel(metadata, preset: preset) ?? "Camera Bridge"
            let secondary = [metadata.lensModel, parameterLabel(metadata, preset: preset)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            draw(primary, in: CGRect(x: textStart, y: stripRect.minY + strip * 0.22, width: textEnd - textStart, height: strip * 0.30), size: max(18, preset.fontSize * scale), bold: true, color: preset.textColor.color.uiColor)
            draw(secondary, in: CGRect(x: textStart, y: stripRect.minY + strip * 0.54, width: textEnd - textStart, height: strip * 0.25), size: max(14, preset.fontSize * 0.70 * scale), bold: false, color: preset.textColor.color.uiColor.withAlphaComponent(0.74))
            if preset.logoEnabled, let logo = logoImage(metadata: metadata, preset: preset) {
                let box = CGRect(x: logoOnRight ? stripRect.maxX - margin - logoWidth : margin, y: stripRect.minY + strip * 0.13, width: logoWidth, height: strip * 0.74)
                logo.withAlpha(preset.logoAlpha).draw(in: aspectFit(logo.size, in: box))
            }
        }
    }

    private func squareBorder(image: UIImage) -> UIImage {
        let source = normalized(image)
        let edge = max(source.size.width, source.size.height) * 1.10
        return UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: edge, height: edge))
            source.draw(in: aspectFit(source.size, in: CGRect(x: edge * 0.045, y: edge * 0.045, width: edge * 0.91, height: edge * 0.91)))
        }
    }

    private func custom(image: UIImage, metadata: PhotoMetadata, preset: WatermarkPreset) -> UIImage {
        let source = normalized(image)
        return UIGraphicsImageRenderer(size: source.size).image { context in
            source.draw(at: .zero)
            let value = [preset.customText, preset.copyrightText, metadata.customText, metadata.copyrightText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "Camera Bridge"
            let margin = max(18, preset.margin)
            let height = max(64, preset.fontSize * 2.1)
            let box = CGRect(x: margin, y: source.size.height - height - margin, width: source.size.width - margin * 2, height: height)
            let path = UIBezierPath(roundedRect: box, cornerRadius: height * 0.25)
            preset.backgroundColor.color.uiColor.withAlphaComponent(preset.backgroundAlpha).setFill(); path.fill()
            draw(value, in: box.insetBy(dx: margin, dy: height * 0.18), size: preset.fontSize, bold: false, color: preset.textColor.color.uiColor)
        }
    }

    private func cameraLabel(_ metadata: PhotoMetadata, preset: WatermarkPreset) -> String? {
        var parts: [String] = []
        if preset.fields.contains(.cameraBrand), let value = metadata.cameraBrand { parts.append(value) }
        if preset.fields.contains(.cameraModel), let value = metadata.cameraModel, !parts.contains(where: { $0.localizedCaseInsensitiveContains(value) }) { parts.append(value) }
        return parts.joined(separator: " ").nilIfEmpty
    }

    private func parameterLabel(_ metadata: PhotoMetadata, preset: WatermarkPreset) -> String {
        var values: [String] = []
        if preset.fields.contains(.focalLength), let value = metadata.focalLength { values.append(value) }
        if preset.fields.contains(.equivalentFocalLength), let value = metadata.equivalentFocalLength { values.append("等效 \(value)") }
        if preset.fields.contains(.aperture), let value = metadata.aperture { values.append(value) }
        if preset.fields.contains(.shutter), let value = metadata.shutterSpeed { values.append(value) }
        if preset.fields.contains(.iso), let value = metadata.iso { values.append("ISO \(value)") }
        if preset.fields.contains(.captureDate), let value = metadata.capturedAt { values.append(value.bridgeDateText) }
        return values.joined(separator: "  ")
    }

    private func logoImage(metadata: PhotoMetadata, preset: WatermarkPreset) -> UIImage? {
        if let logoName = preset.logoName {
            if let image = UIImage(named: logoName) { return image }
            if FileManager.default.fileExists(atPath: logoName), let image = UIImage(contentsOfFile: logoName) { return image }
        }
        guard preset.useBrandLogo, let brand = metadata.cameraBrand?.lowercased() else { return nil }
        let mapping: [(String, String)] = [
            ("nikon", "wm_nikon"), ("canon", "wm_canon"), ("sony", "wm_sony"),
            ("fujifilm", "wm_fujifilm"), ("fuji", "wm_fujifilm"), ("panasonic", "wm_panasonic"),
            ("leica", "wm_leica_logo"), ("hasselblad", "wm_hasselblad"), ("pentax", "wm_pentax"),
            ("ricoh", "wm_ricoh"), ("olympus", "wm_olympus_blue_gold")
        ]
        return mapping.first(where: { brand.contains($0.0) }).flatMap { UIImage(named: $0.1) }
    }

    private func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        return UIGraphicsImageRenderer(size: image.size).image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    private func blurredFill(_ image: UIImage, size: CGSize) -> UIImage? {
        guard let input = CIImage(image: image) else { return nil }
        let scale = max(size.width / input.extent.width, size.height / input.extent.height)
        let transformed = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = transformed.clampedToExtent()
        blur.radius = Float(max(size.width, size.height) * 0.028)
        let origin = CGPoint(x: (transformed.extent.width - size.width) / 2, y: (transformed.extent.height - size.height) / 2)
        guard let output = blur.outputImage?.cropped(to: CGRect(origin: origin, size: size)),
              let cgImage = ciContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private func aspectFit(_ source: CGSize, in bounds: CGRect) -> CGRect {
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func drawCentered(_ text: String, at y: CGFloat, width: CGFloat, size: CGFloat, bold: Bool, color: UIColor) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
        let canvasWidth = UIGraphicsGetCurrentContext()?.boundingBoxOfClipPath.width ?? width
        text.draw(in: CGRect(x: (canvasWidth - width) / 2, y: y, width: width, height: size * 1.4), withAttributes: [.font: font(size, bold: bold), .foregroundColor: color, .paragraphStyle: paragraph])
    }

    private func draw(_ text: String, in rect: CGRect, size: CGFloat, bold: Bool, color: UIColor) {
        text.draw(in: rect, withAttributes: [.font: font(size, bold: bold), .foregroundColor: color])
    }

    private func font(_ size: CGFloat, bold: Bool) -> UIFont {
        UIFont(name: bold ? "AlibabaPuHuiTi-2-85-Bold" : "AlibabaPuHuiTi-2-45-Light", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }
}

private extension Color {
    var uiColor: UIColor { UIColor(self) }
}

private extension UIImage {
    func withAlpha(_ alpha: Double) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { _ in draw(at: .zero, blendMode: .normal, alpha: alpha) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
