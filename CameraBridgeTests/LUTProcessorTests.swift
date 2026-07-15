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
}
