import XCTest
@testable import CameraBridge

final class AdaptiveChunkControllerTests: XCTestCase {
    func testInitializerClampsCurrentToConfiguredBounds() {
        let belowMinimum = AdaptiveChunkController(initial: 1, minimum: 4, maximum: 16)
        let aboveMaximum = AdaptiveChunkController(initial: 32, minimum: 4, maximum: 16)

        XCTAssertEqual(belowMinimum.current, 4)
        XCTAssertEqual(aboveMaximum.current, 16)
    }

    func testRequestLengthUsesRemainingBytesAndNeverReturnsLessThanOne() {
        var controller = AdaptiveChunkController(initial: 8, minimum: 4, maximum: 16)

        XCTAssertEqual(controller.requestLength(remaining: 20), 8)
        XCTAssertEqual(controller.requestLength(remaining: 3), 3)
        XCTAssertEqual(controller.requestLength(remaining: 1), 1)
        XCTAssertEqual(controller.requestLength(remaining: 0), 1)
        XCTAssertEqual(controller.requestLength(remaining: -10), 1)
    }

    func testStableSuccessesDoubleChunkAndRespectMaximum() {
        var controller = AdaptiveChunkController(
            initial: 4,
            minimum: 2,
            maximum: 12,
            stableThreshold: 2
        )

        controller.registerSuccess()
        XCTAssertEqual(controller.current, 4)
        XCTAssertEqual(controller.consecutiveStable, 1)

        controller.registerSuccess()
        XCTAssertEqual(controller.current, 8)
        XCTAssertEqual(controller.consecutiveStable, 0)

        controller.registerSuccess()
        controller.registerSuccess()
        XCTAssertEqual(controller.current, 12)
        XCTAssertEqual(controller.consecutiveStable, 0)
    }

    func testFailureHalvesChunkWithoutCrossingMinimumAndResetsStability() {
        var controller = AdaptiveChunkController(
            initial: 12,
            minimum: 4,
            maximum: 16,
            stableThreshold: 2
        )

        controller.registerSuccess()
        controller.registerFailure()
        XCTAssertEqual(controller.current, 6)
        XCTAssertEqual(controller.consecutiveStable, 0)

        controller.registerFailure()
        XCTAssertEqual(controller.current, 4)
        controller.registerFailure()
        XCTAssertEqual(controller.current, 4)
    }
}
