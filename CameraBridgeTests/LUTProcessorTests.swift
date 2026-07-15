import Compression
import UIKit
import XCTest
@testable import CameraBridge

final class LUTProcessorTests: XCTestCase {
    func testParseCubeParsesTwoByTwoIdentityLUT() throws {
        let text = """
        TITLE "Identity"
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """

        let lut = try LUTProcessor.shared.parseCube(name: "identity.cube", text: text)

        XCTAssertEqual(lut.name, "identity")
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.values.count, 24)
        XCTAssertEqual(lut.values, [
            0, 0, 0,
            1, 0, 0,
            0, 1, 0,
            1, 1, 0,
            0, 0, 1,
            1, 0, 1,
            0, 1, 1,
            1, 1, 1,
        ])
        XCTAssertEqual(lut.domainMin, SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(lut.domainMax, SIMD3<Float>(1, 1, 1))
    }

    func testParseCubePreservesCustomDomain() throws {
        let text = """
        DOMAIN_MIN -1 0.25 0
        DOMAIN_MAX 1 0.75 2
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """

        let lut = try LUTProcessor.shared.parseCube(name: "/tmp/domain.cube", text: text)

        XCTAssertEqual(lut.name, "domain")
        XCTAssertEqual(lut.domainMin, SIMD3<Float>(-1, 0.25, 0))
        XCTAssertEqual(lut.domainMax, SIMD3<Float>(1, 0.75, 2))
    }

    func testParseCubeRejectsIncompleteNonFiniteAndOutOfOrderData() {
        assertMalformed("""
        LUT_3D_SIZE 2
        0 0 0
        """)

        assertMalformed("""
        LUT_3D_SIZE 2
        NaN 0 0
        """)

        assertMalformed("""
        0 0 0
        LUT_3D_SIZE 2
        """)

        assertMalformed("""
        DOMAIN_MIN 1 0 0
        DOMAIN_MAX 1 1 1
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """)
    }

    func testParseHaldPNGRecognizesSquareCLUT() throws {
        let width = 8
        var pixels = [UInt8](repeating: 0, count: width * width * 4)
        for pixel in 0 ..< width * width {
            pixels[pixel * 4] = UInt8((pixel % 4) * 85)
            pixels[pixel * 4 + 1] = UInt8(((pixel / 4) % 4) * 85)
            pixels[pixel * 4 + 2] = UInt8((pixel / 16) * 85)
            pixels[pixel * 4 + 3] = 255
        }
        let context = CGContext(
            data: &pixels, width: width, height: width, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        let image = try XCTUnwrap(context?.makeImage())
        let png = try XCTUnwrap(UIImage(cgImage: image).pngData())

        let parsed = try LUTProcessor.shared.parse(name: "identity.png", data: png)

        XCTAssertEqual(parsed.format, "PNG")
        XCTAssertEqual(parsed.lut.name, "identity")
        XCTAssertEqual(parsed.lut.size, 4)
        XCTAssertEqual(parsed.lut.values.count, 4 * 4 * 4 * 3)
        XCTAssertTrue(parsed.lut.values.allSatisfy { $0.isFinite && (0 ... 1).contains($0) })
    }

    func testParseXMPDecodesAdobeRGBTable() throws {
        var table = Data()
        table.appendLE(UInt32(1))
        table.appendLE(UInt32(1))
        table.appendLE(UInt32(3))
        table.appendLE(UInt32(2))
        for red in 0 ..< 2 {
            for green in 0 ..< 2 {
                for blue in 0 ..< 2 {
                    table.appendLE(UInt16(red == 0 ? 0 : 65_535))
                    table.appendLE(UInt16(green == 0 ? 0 : 65_535))
                    table.appendLE(UInt16(blue == 0 ? 0 : 65_535))
                }
            }
        }
        let compressed = try zlib(table)
        var wrapped = Data()
        wrapped.appendLE(UInt32(table.count))
        wrapped.append(compressed)
        let encoded = base85(wrapped)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
          <rdf:RDF><rdf:Description crs:RGBTable="identity" crs:Table_identity="\(encoded)" /></rdf:RDF>
        </x:xmpmeta>
        """

        let parsed = try LUTProcessor.shared.parse(name: "identity.xmp", data: Data(xml.utf8))

        XCTAssertEqual(parsed.format, "XMP")
        XCTAssertEqual(parsed.lut.size, 2)
        XCTAssertEqual(parsed.lut.values.count, 24)
        XCTAssertEqual(Array(parsed.lut.values.prefix(3)), [Float](repeating: 0, count: 3))
        XCTAssertEqual(Array(parsed.lut.values.suffix(3)), [Float](repeating: 1, count: 3))
    }

    private func assertMalformed(
        _ text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try LUTProcessor.shared.parseCube(name: "invalid.cube", text: text),
            file: file,
            line: line
        ) { error in
            guard case LUTError.malformed = error else {
                return XCTFail("Expected LUTError.malformed, got \(error)", file: file, line: line)
            }
        }
    }

    private func zlib(_ input: Data) throws -> Data {
        var destination = [UInt8](repeating: 0, count: max(256, input.count * 2 + 64))
        let count = destination.withUnsafeMutableBufferPointer { target in
            input.withUnsafeBytes { source in
                compression_encode_buffer(
                    target.baseAddress!, target.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard count > 0 else { throw LUTError.malformed("test zlib encoding failed") }
        return Data(destination.prefix(count))
    }

    private func base85(_ data: Data) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#")
        var output = ""
        var offset = 0
        while offset < data.count {
            let count = min(4, data.count - offset)
            var value: UInt64 = 0
            for byte in 0 ..< count { value |= UInt64(data[offset + byte]) << (8 * byte) }
            for _ in 0 ..< count + 1 {
                output.append(alphabet[Int(value % 85)])
                value /= 85
            }
            offset += count
        }
        return output
    }
}
