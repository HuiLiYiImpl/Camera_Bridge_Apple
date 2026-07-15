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

    func composition(for asset: AVAsset, lut: CubeLUT?, intensity: Double) -> AVVideoComposition? {
        guard let lut else { return nil }
        return AVVideoComposition(asset: asset) { [lutProcessor] request in
            let source = request.sourceImage.clampedToExtent()
            let graded = lutProcessor.colorCubeFilter(lut, input: source)
            let amount = min(max(intensity, 0), 1)
            let result: CIImage
            if amount >= 0.999 {
                result = graded
            } else {
                let alpha = graded.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)
                ])
                result = alpha.composited(over: source)
            }
            request.finish(with: result.cropped(to: request.sourceImage.extent), context: nil)
        }
    }

    func export(
        sourceURL: URL,
        destinationURL: URL,
        lut: CubeLUT?,
        intensity: Double,
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
        exporter.videoComposition = composition(for: asset, lut: lut, intensity: intensity)
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
