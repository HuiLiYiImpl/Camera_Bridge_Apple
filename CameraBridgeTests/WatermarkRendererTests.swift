import UIKit
import XCTest
@testable import CameraBridge

final class WatermarkRendererTests: XCTestCase {
    private let metadata = PhotoMetadata(
        cameraBrand: "Nikon",
        cameraModel: "Z f",
        lensModel: "NIKKOR Z 40mm f/2",
        iso: 100,
        shutterSpeed: "1/250s",
        aperture: "f/2.8",
        focalLength: "40mm",
        equivalentFocalLength: "40mm",
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        customText: "Camera Bridge",
        copyrightText: "HuiLiYiImpl"
    )

    func testBuiltInLayoutsProduceExpectedCanvasGeometry() throws {
        let source = makeImage(size: CGSize(width: 200, height: 100))

        var atmosphere = WatermarkPreset.defaults[0]
        atmosphere.layout = .atmosphere
        let atmosphereImage = try WatermarkRenderer.shared.render(image: source, metadata: metadata, preset: atmosphere)
        XCTAssertEqual(atmosphereImage.size.width, 200, accuracy: 0.5)
        XCTAssertEqual(atmosphereImage.size.height, 250, accuracy: 0.5)

        var strip = WatermarkPreset.defaults[1]
        strip.layout = .rightParameters
        let stripImage = try WatermarkRenderer.shared.render(image: source, metadata: metadata, preset: strip)
        XCTAssertEqual(stripImage.size.width, 200, accuracy: 0.5)
        XCTAssertGreaterThan(stripImage.size.height, source.size.height)

        var border = WatermarkPreset.defaults[3]
        border.layout = .whiteBorder
        let borderImage = try WatermarkRenderer.shared.render(image: source, metadata: metadata, preset: border)
        XCTAssertEqual(borderImage.size.width, borderImage.size.height, accuracy: 0.5)
        XCTAssertGreaterThan(borderImage.size.width, source.size.width)
    }

    func testCustomWatermarkKeepsCanvasAndChangesPixels() throws {
        let source = makeImage(size: CGSize(width: 240, height: 160))
        var preset = WatermarkPreset.defaults[0]
        preset.layout = .custom
        preset.customText = "Camera Bridge Test"
        preset.backgroundColor = 0xCC000000
        preset.textColor = 0xFFFFFFFF

        let output = try WatermarkRenderer.shared.render(image: source, metadata: metadata, preset: preset)

        XCTAssertEqual(output.size, source.size)
        XCTAssertNotEqual(output.pngData(), source.pngData())
    }

    func testJPEGWriterPreservesCoreExifFields() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-bridge-metadata-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }

        try MediaLibraryService.writeJPEG(
            image: makeImage(size: CGSize(width: 160, height: 100)),
            metadata: metadata,
            quality: 0.91,
            to: output
        )
        let data = try Data(contentsOf: output)
        let decoded = PhotoMetadataReader.read(from: data)

        XCTAssertEqual(decoded.cameraBrand, metadata.cameraBrand)
        XCTAssertEqual(decoded.cameraModel, metadata.cameraModel)
        XCTAssertEqual(decoded.lensModel, metadata.lensModel)
        XCTAssertEqual(decoded.iso, metadata.iso)
        XCTAssertEqual(decoded.copyrightText, metadata.copyrightText)
    }

    private func makeImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.18, green: 0.42, blue: 0.72, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: size.width * 0.2, y: size.height * 0.2, width: size.width * 0.25, height: size.height * 0.3))
        }
    }
}
