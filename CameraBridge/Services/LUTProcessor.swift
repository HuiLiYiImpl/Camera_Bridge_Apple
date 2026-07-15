import Compression
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

enum LUTError: LocalizedError {
    case unsupportedFormat
    case fileTooLarge
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "仅支持 .cube、Hald CLUT .png 和 Adobe .xmp LUT"
        case .fileTooLarge: "LUT 文件过大"
        case .malformed(let message): "LUT 格式错误：\(message)"
        }
    }
}

final class LUTProcessor: @unchecked Sendable {
    static let shared = LUTProcessor()
    private let context = CIContext(options: [.cacheIntermediates: true])

    func parse(name: String, data: Data) throws -> (lut: CubeLUT, format: String) {
        guard data.count <= 32 * 1024 * 1024 else { throw LUTError.fileTooLarge }
        switch name.split(separator: ".").last?.lowercased() {
        case "cube": return (try parseCube(name: name, text: String(decoding: data, as: UTF8.self)), "CUBE")
        case "png": return (try parseHaldPNG(name: name, data: data), "PNG")
        case "xmp": return (try parseXMP(name: name, data: data), "XMP")
        default: throw LUTError.unsupportedFormat
        }
    }

    func parseCube(name: String, text: String) throws -> CubeLUT {
        guard text.utf8.count <= 32 * 1024 * 1024 else { throw LUTError.fileTooLarge }
        var size = 0
        var values: [Float] = []
        var minimum = SIMD3<Float>(repeating: 0)
        var maximum = SIMD3<Float>(repeating: 1)

        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let first = parts.first else { continue }
            switch first.uppercased() {
            case "TITLE", "LUT_1D_SIZE": continue
            case "LUT_3D_SIZE":
                guard parts.count >= 2, let parsed = Int(parts[1]), (2 ... 65).contains(parsed) else {
                    throw LUTError.malformed("不支持的 3D 尺寸")
                }
                size = parsed
                values.reserveCapacity(size * size * size * 3)
            case "DOMAIN_MIN", "DOMAIN_MAX":
                guard parts.count >= 4,
                      let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]),
                      x.isFinite, y.isFinite, z.isFinite else {
                    throw LUTError.malformed("\(first) 数据不完整")
                }
                if first.uppercased() == "DOMAIN_MIN" { minimum = SIMD3(x, y, z) }
                else { maximum = SIMD3(x, y, z) }
            default:
                guard size > 0, parts.count >= 3 else { throw LUTError.malformed("LUT_3D_SIZE 必须位于数据之前") }
                for value in parts.prefix(3) {
                    guard let number = Float(value), number.isFinite else { throw LUTError.malformed("包含非法数值") }
                    values.append(number)
                }
            }
        }
        guard (2 ... 65).contains(size), values.count == size * size * size * 3 else {
            throw LUTError.malformed("LUT 数据数量不完整")
        }
        guard minimum.x < maximum.x, minimum.y < maximum.y, minimum.z < maximum.z else {
            throw LUTError.malformed("DOMAIN_MIN 必须小于 DOMAIN_MAX")
        }
        let cleanName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        return CubeLUT(name: cleanName, size: size, values: values, domainMin: minimum, domainMax: maximum)
    }

    func apply(_ lut: CubeLUT, to image: UIImage, intensity: Double = 1) throws -> UIImage {
        guard var source = CIImage(image: image) else { throw LUTError.malformed("无法读取预览图片") }
        source = source.oriented(forExifOrientation: image.imageOrientation.exifOrientation)

        let domain = CIFilter.colorMatrix()
        domain.inputImage = source
        let ranges = lut.domainMax - lut.domainMin
        domain.rVector = CIVector(x: CGFloat(1 / ranges.x), y: 0, z: 0, w: 0)
        domain.gVector = CIVector(x: 0, y: CGFloat(1 / ranges.y), z: 0, w: 0)
        domain.bVector = CIVector(x: 0, y: 0, z: CGFloat(1 / ranges.z), w: 0)
        domain.biasVector = CIVector(
            x: CGFloat(-lut.domainMin.x / ranges.x),
            y: CGFloat(-lut.domainMin.y / ranges.y),
            z: CGFloat(-lut.domainMin.z / ranges.z),
            w: 0
        )

        let cube = CIFilter.colorCube()
        cube.inputImage = domain.outputImage
        cube.cubeDimension = Float(lut.size)
        cube.cubeData = rgbaCubeData(lut)
        guard let graded = cube.outputImage else { throw LUTError.malformed("Core Image 无法应用 LUT") }
        let amount = min(max(intensity, 0), 1)
        let output: CIImage
        if amount >= 0.999 {
            output = graded
        } else if amount <= 0.001 {
            output = source
        } else {
            let alpha = CIFilter.colorMatrix()
            alpha.inputImage = graded
            alpha.aVector = CIVector(x: 0, y: 0, z: 0, w: amount)
            let composite = CIFilter.sourceOverCompositing()
            composite.inputImage = alpha.outputImage
            composite.backgroundImage = source
            output = composite.outputImage ?? source
        }
        guard let cgImage = context.createCGImage(output, from: source.extent) else {
            throw LUTError.malformed("无法渲染 LUT 图片")
        }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    func colorCubeFilter(_ lut: CubeLUT, input: CIImage) -> CIImage {
        let cube = CIFilter.colorCube()
        cube.inputImage = input
        cube.cubeDimension = Float(lut.size)
        cube.cubeData = rgbaCubeData(lut)
        return cube.outputImage ?? input
    }

    private func rgbaCubeData(_ lut: CubeLUT) -> Data {
        var rgba = [Float]()
        rgba.reserveCapacity(lut.size * lut.size * lut.size * 4)
        for index in stride(from: 0, to: lut.values.count, by: 3) {
            rgba.append(lut.values[index])
            rgba.append(lut.values[index + 1])
            rgba.append(lut.values[index + 2])
            rgba.append(1)
        }
        return rgba.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.size)
        }
    }

    private func parseHaldPNG(name: String, data: Data) throws -> CubeLUT {
        guard let image = UIImage(data: data)?.cgImage else { throw LUTError.malformed("无法读取 PNG") }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= 16_777_216 else { throw LUTError.malformed("PNG 尺寸异常") }
        let size: Int
        let coordinate: (Int, Int, Int) -> (Int, Int)
        if width == height {
            let level = Int(round(pow(Double(width), 1.0 / 3.0)))
            guard level >= 2, level * level * level == width, level * level <= 65 else {
                throw LUTError.malformed("不是可识别的 Hald CLUT")
            }
            size = level * level
            coordinate = { red, green, blue in
                let linear = (blue * size + green) * size + red
                return (linear % width, linear / width)
            }
        } else if width == height * height, (2 ... 65).contains(height) {
            size = height
            coordinate = { red, green, blue in (red + green * size, blue) }
        } else {
            throw LUTError.malformed("不是可识别的 Hald CLUT")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw LUTError.malformed("无法解码 PNG 像素") }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var values = [Float](repeating: 0, count: size * size * size * 3)
        for blue in 0 ..< size {
            for green in 0 ..< size {
                for red in 0 ..< size {
                    let (x, y) = coordinate(red, green, blue)
                    guard x < width, y < height else { throw LUTError.malformed("PNG LUT 坐标越界") }
                    let pixel = (y * width + x) * 4
                    let target = ((blue * size + green) * size + red) * 3
                    values[target] = Float(pixels[pixel]) / 255
                    values[target + 1] = Float(pixels[pixel + 1]) / 255
                    values[target + 2] = Float(pixels[pixel + 2]) / 255
                }
            }
        }
        return CubeLUT(name: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, size: size, values: values, domainMin: .zero, domainMax: .one)
    }

    private func parseXMP(name: String, data: Data) throws -> CubeLUT {
        let text = String(decoding: data, as: UTF8.self)
        guard !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else {
            throw LUTError.malformed("XMP 禁止使用外部实体")
        }
        let delegate = XMPTableParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let encoded = delegate.encodedTable else { throw LUTError.malformed("XMP 不包含 RGB Table") }
        let compressed = try decodeBase85(encoded)
        guard compressed.count >= 4 else { throw LUTError.malformed("XMP 压缩数据不完整") }
        var sizeReader = PTPReader(compressed)
        let expected = Int(try sizeReader.u32())
        guard (1 ... 16 * 1024 * 1024).contains(expected) else { throw LUTError.malformed("XMP 解压数据过大") }
        let payload = compressed.dropFirst(4)
        var output = [UInt8](repeating: 0, count: expected)
        let decoded = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, expected,
                    source.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard decoded == expected else { throw LUTError.malformed("XMP 解压数据长度错误") }
        var reader = PTPReader(Data(output))
        guard try reader.u32() == 1, try reader.u32() == 1, try reader.u32() == 3 else {
            throw LUTError.malformed("不支持的 XMP RGB Table")
        }
        let size = Int(try reader.u32())
        guard (2 ... 65).contains(size) else { throw LUTError.malformed("不支持的 XMP LUT 尺寸") }
        var values = [Float](repeating: 0, count: size * size * size * 3)
        for red in 0 ..< size {
            for green in 0 ..< size {
                for blue in 0 ..< size {
                    let index = ((blue * size + green) * size + red) * 3
                    values[index] = Float(try reader.u16()) / 65_535
                    values[index + 1] = Float(try reader.u16()) / 65_535
                    values[index + 2] = Float(try reader.u16()) / 65_535
                }
            }
        }
        return CubeLUT(name: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent, size: size, values: values, domainMin: .zero, domainMax: .one)
    }

    private func decodeBase85(_ value: String) throws -> Data {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?`'|()[]{}@%$#")
        var lookup: [Character: Int] = [:]
        for (index, character) in alphabet.enumerated() { lookup[character] = index }
        var output = Data()
        var phase = 0
        var accumulated: UInt64 = 0
        var multipliers: [UInt64] = [1]
        for _ in 1 ..< 5 { multipliers.append(multipliers.last! * 85) }
        for character in value {
            guard let digit = lookup[character] else { continue }
            accumulated += UInt64(digit) * multipliers[phase]
            phase += 1
            if phase == 5 {
                for byte in 0 ..< 4 { output.append(UInt8(truncatingIfNeeded: accumulated >> (8 * byte))) }
                phase = 0
                accumulated = 0
            }
        }
        if phase > 1 {
            for byte in 0 ..< phase - 1 { output.append(UInt8(truncatingIfNeeded: accumulated >> (8 * byte))) }
        }
        return output
    }
}

private final class XMPTableParser: NSObject, XMLParserDelegate {
    private var tableID: String?
    private(set) var encodedTable: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        for (key, value) in attributeDict {
            let local = key.split(separator: ":").last.map(String.init) ?? key
            if local == "RGBTable", !value.isEmpty { tableID = value }
        }
        for (key, value) in attributeDict {
            let local = key.split(separator: ":").last.map(String.init) ?? key
            if let tableID, local == "Table_\(tableID)", !value.isEmpty { encodedTable = value }
            else if encodedTable == nil, local.hasPrefix("Table_"), !value.isEmpty { encodedTable = value }
        }
    }
}

private extension UIImage.Orientation {
    var exifOrientation: Int32 {
        switch self {
        case .up: 1
        case .down: 3
        case .left: 8
        case .right: 6
        case .upMirrored: 2
        case .downMirrored: 4
        case .leftMirrored: 5
        case .rightMirrored: 7
        @unknown default: 1
        }
    }
}

private extension SIMD3 where Scalar == Float {
    static var one: SIMD3<Float> { SIMD3(repeating: 1) }
}
