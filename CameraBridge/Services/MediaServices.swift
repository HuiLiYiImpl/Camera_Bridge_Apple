import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import UIKit

enum MediaLibraryService {
    static func saveToPhotos(fileURL: URL, kind: MediaKind) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw MediaProcessingError.photoLibraryDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            request.addResource(with: kind == .video ? .video : .photo, fileURL: fileURL, options: options)
        }
    }

    static func writeJPEG(
        image: UIImage,
        metadata: PhotoMetadata,
        quality: Double,
        to url: URL
    ) throws {
        guard let cgImage = image.cgImage,
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else { throw MediaProcessingError.cannotWriteImage }
        var tiff: [String: Any] = [:]
        var exif: [String: Any] = [:]
        if let value = metadata.cameraBrand { tiff[kCGImagePropertyTIFFMake as String] = value }
        if let value = metadata.cameraModel { tiff[kCGImagePropertyTIFFModel as String] = value }
        if let value = metadata.copyrightText { tiff[kCGImagePropertyTIFFCopyright as String] = value }
        if let value = metadata.lensModel { exif[kCGImagePropertyExifLensModel as String] = value }
        if let value = metadata.iso { exif[kCGImagePropertyExifISOSpeedRatings as String] = [value] }
        if let value = metadata.capturedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            exif[kCGImagePropertyExifDateTimeOriginal as String] = formatter.string(from: value)
        }
        let properties: [String: Any] = [
            kCGImageDestinationLossyCompressionQuality as String: min(max(quality, 0.1), 1),
            kCGImagePropertyTIFFDictionary as String: tiff,
            kCGImagePropertyExifDictionary as String: exif
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaProcessingError.cannotWriteImage }
    }
}

final class VideoProcessor: @unchecked Sendable {
    static let shared = VideoProcessor()
    private let lutProcessor = LUTProcessor.shared

    /// Creates the same composition used by export so callers can attach it to
    /// an `AVPlayerItem` for a faithful real-time preview.
    func makeVideoComposition(
        asset: AVAsset,
        lut: CubeLUT?,
        intensity: Double,
        rotation: Int = 0,
        watermark: WatermarkPreset? = nil,
        metadata: PhotoMetadata = PhotoMetadata()
    ) -> AVVideoComposition? {
        let effects = VideoFrameEffects(rotation: rotation, watermark: watermark, metadata: metadata)
        guard lut != nil || effects.hasVisibleEffects else { return nil }

        let composition = AVMutableVideoComposition(
            asset: asset,
            applyingCIFiltersWithHandler: { [lutProcessor, effects] request in
                autoreleasepool {
                    let sourceExtent = request.sourceImage.extent
                    var output = request.sourceImage

                    if let lut {
                        let source = request.sourceImage.clampedToExtent()
                        let graded = lutProcessor.colorCubeFilter(lut, input: source)
                        let amount = min(max(intensity, 0), 1)
                        if amount >= 0.999 {
                            output = graded
                        } else if amount <= 0.001 {
                            output = source
                        } else {
                            let mask = CIImage(
                                color: CIColor(red: amount, green: amount, blue: amount, alpha: 1)
                            ).cropped(to: sourceExtent)
                            output = graded.applyingFilter("CIBlendWithMask", parameters: [
                                kCIInputBackgroundImageKey: source,
                                kCIInputMaskImageKey: mask
                            ])
                        }
                    }

                    output = effects.apply(to: output.cropped(to: sourceExtent))
                    request.finish(with: output, context: nil)
                }
            }
        )
        effects.configure(baseSize: composition.renderSize)
        composition.renderSize = effects.outputSize
        return composition
    }

    func export(
        sourceURL: URL,
        destinationURL: URL,
        lut: CubeLUT?,
        intensity: Double,
        rotation: Int = 0,
        watermark: WatermarkPreset? = nil,
        metadata: PhotoMetadata = PhotoMetadata(),
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MediaProcessingError.videoExportFailed("设备不支持导出")
        }
        try? FileManager.default.removeItem(at: destinationURL)
        exporter.outputURL = destinationURL
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition = makeVideoComposition(
            asset: asset,
            lut: lut,
            intensity: intensity,
            rotation: rotation,
            watermark: watermark,
            metadata: metadata
        )
        let poller = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                progress(Double(exporter.progress))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        progress(1)
        switch exporter.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw MediaProcessingError.videoExportFailed(exporter.error?.localizedDescription ?? "未知错误")
        }
    }
}

private final class VideoFrameEffects: @unchecked Sendable {
    private let rotation: Int
    private let watermark: WatermarkPreset?
    private let metadata: PhotoMetadata
    private var overlay: CIImage?
    private(set) var outputSize = CGSize(width: 1, height: 1)

    init(rotation: Int, watermark: WatermarkPreset?, metadata: PhotoMetadata) {
        self.rotation = ((rotation % 360) + 360) % 360
        self.watermark = watermark
        self.metadata = metadata
    }

    var hasVisibleEffects: Bool { rotation != 0 || watermark != nil }

    func configure(baseSize: CGSize) {
        let safeSize = CGSize(width: max(baseSize.width, 1), height: max(baseSize.height, 1))
        if rotation == 0 {
            outputSize = safeSize
        } else {
            let radians = -CGFloat(rotation) * .pi / 180
            let rotated = CGRect(origin: .zero, size: safeSize).applying(CGAffineTransform(rotationAngle: radians))
            outputSize = CGSize(width: max(abs(rotated.width), 1), height: max(abs(rotated.height), 1))
        }
        if let watermark {
            overlay = VideoWatermarkOverlay.make(size: outputSize, preset: watermark, metadata: metadata)
        }
    }

    func apply(to image: CIImage) -> CIImage {
        var output = image.transformed(by: CGAffineTransform(
            translationX: -image.extent.minX,
            y: -image.extent.minY
        ))
        if rotation != 0 {
            output = output.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(rotation) * .pi / 180))
            output = output.transformed(by: CGAffineTransform(
                translationX: -output.extent.minX,
                y: -output.extent.minY
            ))
        }
        let target = CGRect(origin: .zero, size: outputSize)
        output = output.cropped(to: target)
        if let overlay { output = overlay.composited(over: output) }
        return output.cropped(to: target)
    }
}

private enum VideoWatermarkOverlay {
    static func make(size: CGSize, preset: WatermarkPreset, metadata: PhotoMetadata) -> CIImage? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            switch preset.layout {
            case .atmosphere:
                drawAtmosphere(in: context.cgContext, size: size, preset: preset, metadata: metadata)
            case .leftParameters:
                drawInformationStrip(in: context.cgContext, size: size, preset: preset, metadata: metadata, logoOnRight: false)
            case .rightParameters:
                drawInformationStrip(in: context.cgContext, size: size, preset: preset, metadata: metadata, logoOnRight: true)
            case .whiteBorder:
                drawBorder(in: context.cgContext, size: size, preset: preset)
            case .custom:
                drawCustom(in: context.cgContext, size: size, preset: preset, metadata: metadata)
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage)
    }

    private static func drawAtmosphere(
        in context: CGContext,
        size: CGSize,
        preset: WatermarkPreset,
        metadata: PhotoMetadata
    ) {
        let scale = drawingScale(for: size)
        let panelHeight = max(size.height * 0.15, 116 * scale)
        let panel = CGRect(x: 0, y: size.height - panelHeight, width: size.width, height: panelHeight)
        context.setFillColor(color(preset.backgroundColor, alpha: max(preset.backgroundAlpha, 0.45)).cgColor)
        context.fill(panel)

        let lines = labels(preset: preset, metadata: metadata)
        let primary = lines.primary ?? lines.caption ?? "Camera Bridge"
        let secondary = [lines.secondary, lines.caption].compactMap { $0 }.joined(separator: "  ·  ")
        drawText(
            primary,
            in: CGRect(x: size.width * 0.08, y: panel.minY + panelHeight * 0.18, width: size.width * 0.84, height: panelHeight * 0.34),
            font: font(size: max(22 * scale, CGFloat(preset.fontSize) * scale), bold: true),
            color: color(preset.textColor),
            alignment: .center
        )
        if !secondary.isEmpty {
            drawText(
                secondary,
                in: CGRect(x: size.width * 0.08, y: panel.minY + panelHeight * 0.56, width: size.width * 0.84, height: panelHeight * 0.26),
                font: font(size: max(15 * scale, CGFloat(preset.fontSize) * 0.68 * scale), bold: false),
                color: color(preset.textColor, alpha: 0.8),
                alignment: .center
            )
        }
    }

    private static func drawInformationStrip(
        in context: CGContext,
        size: CGSize,
        preset: WatermarkPreset,
        metadata: PhotoMetadata,
        logoOnRight: Bool
    ) {
        let scale = drawingScale(for: size)
        let stripHeight = max(size.height * 0.12, 96 * scale)
        let strip = CGRect(x: 0, y: size.height - stripHeight, width: size.width, height: stripHeight)
        context.setFillColor(color(preset.backgroundColor, alpha: preset.backgroundAlpha).cgColor)
        context.fill(strip)

        let margin = max(22 * scale, CGFloat(preset.margin) * scale)
        let logoBoxWidth = preset.logoEnabled ? stripHeight * 1.15 * CGFloat(preset.logoScale) : 0
        let textMinX = logoOnRight ? margin : margin + logoBoxWidth
        let textMaxX = logoOnRight ? size.width - margin - logoBoxWidth : size.width - margin
        let lines = labels(preset: preset, metadata: metadata)
        let primary = lines.primary ?? lines.caption ?? "Camera Bridge"
        let secondary = [lines.secondary, lines.caption].compactMap { $0 }.joined(separator: "  ·  ")

        drawText(
            primary,
            in: CGRect(x: textMinX, y: strip.minY + stripHeight * 0.17, width: max(textMaxX - textMinX, 1), height: stripHeight * 0.34),
            font: font(size: max(20 * scale, CGFloat(preset.fontSize) * scale), bold: true),
            color: color(preset.textColor),
            alignment: logoOnRight ? .left : .right
        )
        if !secondary.isEmpty {
            drawText(
                secondary,
                in: CGRect(x: textMinX, y: strip.minY + stripHeight * 0.55, width: max(textMaxX - textMinX, 1), height: stripHeight * 0.26),
                font: font(size: max(14 * scale, CGFloat(preset.fontSize) * 0.66 * scale), bold: false),
                color: color(preset.textColor, alpha: 0.72),
                alignment: logoOnRight ? .left : .right
            )
        }

        if preset.logoEnabled, let logo = logoImage(preset: preset, metadata: metadata) {
            let box = CGRect(
                x: logoOnRight ? size.width - margin - logoBoxWidth : margin,
                y: strip.minY + stripHeight * 0.16,
                width: logoBoxWidth,
                height: stripHeight * 0.68
            )
            logo.draw(in: aspectFit(logo.size, in: box), blendMode: .normal, alpha: preset.logoAlpha)
        }
        if preset.showBorder {
            context.setStrokeColor(color(preset.textColor, alpha: 0.35).cgColor)
            context.setLineWidth(max(scale, 1))
            context.stroke(strip.insetBy(dx: max(scale, 1), dy: max(scale, 1)))
        }
    }

    private static func drawBorder(in context: CGContext, size: CGSize, preset: WatermarkPreset) {
        let scale = drawingScale(for: size)
        let thickness = max(CGFloat(preset.frameThickness) * scale, min(size.width, size.height) * 0.018)
        context.setStrokeColor(color(preset.backgroundColor).cgColor)
        context.setLineWidth(thickness)
        context.stroke(CGRect(origin: .zero, size: size).insetBy(dx: thickness / 2, dy: thickness / 2))
    }

    private static func drawCustom(
        in context: CGContext,
        size: CGSize,
        preset: WatermarkPreset,
        metadata: PhotoMetadata
    ) {
        let scale = drawingScale(for: size)
        let caption = labels(preset: preset, metadata: metadata).caption ?? "Camera Bridge"
        let font = font(size: max(18 * scale, CGFloat(preset.fontSize) * scale), bold: false)
        let margin = max(22 * scale, CGFloat(preset.margin) * scale)
        let measured = (caption as NSString).size(withAttributes: [.font: font])
        let box = CGRect(
            x: margin,
            y: size.height - margin - measured.height - 32 * scale,
            width: min(measured.width + 44 * scale, size.width - margin * 2),
            height: measured.height + 32 * scale
        )
        let path = UIBezierPath(roundedRect: box, cornerRadius: box.height * 0.28)
        color(preset.backgroundColor, alpha: preset.backgroundAlpha).setFill()
        path.fill()
        drawText(
            caption,
            in: box.insetBy(dx: 22 * scale, dy: 12 * scale),
            font: font,
            color: color(preset.textColor),
            alignment: .left
        )
    }

    private static func labels(
        preset: WatermarkPreset,
        metadata: PhotoMetadata
    ) -> (primary: String?, secondary: String?, caption: String?) {
        var camera: [String] = []
        if preset.fields.contains(.cameraBrand), let value = clean(metadata.cameraBrand) { camera.append(value) }
        if preset.fields.contains(.cameraModel), let value = clean(metadata.cameraModel), !camera.contains(value) { camera.append(value) }

        var details: [String] = []
        if preset.fields.contains(.lensModel), let value = clean(metadata.lensModel) { details.append(value) }
        if preset.fields.contains(.focalLength), let value = clean(metadata.focalLength) { details.append(value) }
        if preset.fields.contains(.equivalentFocalLength), let value = clean(metadata.equivalentFocalLength) { details.append("等效 \(value)") }
        if preset.fields.contains(.aperture), let value = clean(metadata.aperture) { details.append(value) }
        if preset.fields.contains(.shutter), let value = clean(metadata.shutterSpeed) { details.append(value) }
        if preset.fields.contains(.iso), let value = metadata.iso { details.append("ISO \(value)") }
        if preset.fields.contains(.captureDate), let value = metadata.capturedAt { details.append(value.bridgeDateText) }

        var captions: [String] = []
        if preset.layout == .custom || preset.fields.contains(.customText), let value = clean(preset.customText) { captions.append(value) }
        if preset.layout == .custom || preset.fields.contains(.copyright), let value = clean(preset.copyrightText) { captions.append("© \(value)") }
        return (
            camera.joined(separator: " ").nilIfEmpty,
            details.joined(separator: "  ·  ").nilIfEmpty,
            captions.joined(separator: "  ·  ").nilIfEmpty
        )
    }

    private static func logoImage(preset: WatermarkPreset, metadata: PhotoMetadata) -> UIImage? {
        if let logoName = clean(preset.logoName) {
            let fileURL: URL?
            if logoName.hasPrefix("file://") { fileURL = URL(string: logoName) }
            else if logoName.hasPrefix("/") { fileURL = URL(fileURLWithPath: logoName) }
            else { fileURL = nil }
            if let fileURL, let image = UIImage(contentsOfFile: fileURL.path) { return image }
            if let image = UIImage(named: logoName) { return image }
        }
        guard preset.useBrandLogo, let brand = clean(metadata.cameraBrand)?.lowercased() else { return nil }
        let mapping: [(String, String)] = [
            ("nikon", "wm_nikon"), ("canon", "wm_canon"), ("sony", "wm_sony"),
            ("fujifilm", "wm_fujifilm"), ("fuji", "wm_fujifilm"), ("panasonic", "wm_panasonic"),
            ("leica", "wm_leica_logo"), ("hasselblad", "wm_hasselblad"), ("pentax", "wm_pentax"),
            ("ricoh", "wm_ricoh"), ("olympus", "wm_olympus_blue_gold")
        ]
        return mapping.first(where: { brand.contains($0.0) }).flatMap { UIImage(named: $0.1) }
    }

    private static func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }

    private static func color(_ argb: UInt32, alpha: Double = 1) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255 * CGFloat(min(max(alpha, 0), 1))
        )
    }

    private static func font(size: CGFloat, bold: Bool) -> UIFont {
        UIFont(name: bold ? "AlibabaPuHuiTi-2-85-Bold" : "AlibabaPuHuiTi-2-45-Light", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    private static func drawingScale(for size: CGSize) -> CGFloat {
        max(min(size.width, size.height) / 1_080, 0.5)
    }

    private static func aspectFit(_ source: CGSize, in bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return bounds }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let fitted = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
