import XCTest
@testable import CameraBridge

final class PTPProtocolTests: XCTestCase {
    func testPacketEncodesLittleEndianHeaderAndPayload() throws {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let encoded = PTPIPCodec.packet(type: 0x0102_0304, payload: payload)

        XCTAssertEqual(
            encoded,
            Data([
                0x0B, 0x00, 0x00, 0x00,
                0x04, 0x03, 0x02, 0x01,
                0xAA, 0xBB, 0xCC,
            ])
        )

        let decoded = try PTPIPCodec.decodePacket(
            header: Data(encoded.prefix(8)),
            payload: Data(encoded.dropFirst(8))
        )
        XCTAssertEqual(decoded, PTPPacket(type: 0x0102_0304, payload: payload))
    }

    func testReaderReadsLittleEndianScalarsStringsArraysAndRemainingBytes() throws {
        var data = Data()
        data.append(0xAB)
        data.appendLE(UInt16(0x1234))
        data.appendLE(UInt32(0x89AB_CDEF))
        data.appendLE(UInt64(0x0123_4567_89AB_CDEF))
        data.append(3)
        data.append("Zf".data(using: .utf16LittleEndian)!)
        data.append(contentsOf: [0, 0])
        data.append(PTPIPCodec.utf16z("Nikon"))
        data.appendLE(UInt32(2))
        data.appendLE(UInt16(0x1001))
        data.appendLE(UInt16(0x1002))
        data.appendLE(UInt32(2))
        data.appendLE(UInt32(7))
        data.appendLE(UInt32(9))
        data.append(contentsOf: [0xFE, 0xED])

        var reader = PTPReader(data)
        XCTAssertEqual(try reader.u8(), 0xAB)
        XCTAssertEqual(try reader.u16(), 0x1234)
        XCTAssertEqual(try reader.u32(), 0x89AB_CDEF)
        XCTAssertEqual(try reader.u64(), 0x0123_4567_89AB_CDEF)
        XCTAssertEqual(try reader.ptpString(), "Zf")
        XCTAssertEqual(try reader.nullTerminatedUTF16(), "Nikon")
        XCTAssertEqual(try reader.u16Array(), [0x1001, 0x1002])
        XCTAssertEqual(try reader.u32Array(), [7, 9])
        XCTAssertEqual(try reader.remaining(), Data([0xFE, 0xED]))
    }

    func testReaderRejectsTruncatedScalarAndUnterminatedUTF16() {
        var scalarReader = PTPReader(Data([0x01, 0x02, 0x03]))
        XCTAssertThrowsError(try scalarReader.u32()) { error in
            XCTAssertEqual(error as? PTPError, .invalidPacket("数据被截断"))
        }

        var stringReader = PTPReader(Data([0x4E, 0x00, 0x69, 0x00]))
        XCTAssertThrowsError(try stringReader.nullTerminatedUTF16()) { error in
            XCTAssertEqual(error as? PTPError, .invalidPacket("UTF-16 字符串缺少终止符"))
        }
    }

    func testDecodePacketRejectsTruncatedHeaderAndMismatchedDeclaredLength() {
        XCTAssertThrowsError(
            try PTPIPCodec.decodePacket(header: Data([0x08, 0, 0, 0]), payload: Data())
        ) { error in
            XCTAssertEqual(error as? PTPError, .invalidPacket("数据被截断"))
        }

        var header = Data()
        header.appendLE(UInt32(12))
        header.appendLE(UInt32(6))
        XCTAssertThrowsError(
            try PTPIPCodec.decodePacket(header: header, payload: Data([0x01, 0x02, 0x03]))
        ) { error in
            XCTAssertEqual(error as? PTPError, .invalidPacket("包长度不正确"))
        }
    }

    func testOperationEncodesOnlyFirstFiveParameters() throws {
        let encoded = PTPIPCodec.operation(
            operation: 0x101B,
            transaction: 0x1122_3344,
            parameters: [1, 2, 3, 4, 5, 6, 7]
        )

        XCTAssertEqual(encoded.count, 8 + 4 + 2 + 4 + 5 * 4)
        let packet = try PTPIPCodec.decodePacket(
            header: Data(encoded.prefix(8)),
            payload: Data(encoded.dropFirst(8))
        )
        XCTAssertEqual(packet.type, 6)

        var reader = PTPReader(packet.payload)
        XCTAssertEqual(try reader.u32(), 1)
        XCTAssertEqual(try reader.u16(), 0x101B)
        XCTAssertEqual(try reader.u32(), 0x1122_3344)
        XCTAssertEqual(try (0 ..< 5).map { _ in try reader.u32() }, [1, 2, 3, 4, 5])
        XCTAssertTrue(try reader.remaining().isEmpty)
    }
}
