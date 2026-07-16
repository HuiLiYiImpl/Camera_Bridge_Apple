import XCTest
import UIKit
@testable import CameraBridge

final class ParityModelTests: XCTestCase {
    func testLegacyConfigDefaultsNewAutomaticConnectionFlags() throws {
        let json = #"{"host":"10.0.0.1","port":15740,"autoExport":false}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(CameraConfig.self, from: json)
        XCTAssertTrue(config.wifiAutoRestore)
        XCTAssertTrue(config.usbAutoRead)
        XCTAssertEqual(config.host, "10.0.0.1")
    }

    func testLightingTreeSplitMergeAndRatioClamp() {
        var root = LightNode.root(for: .single)
        let original = root.firstLeafID
        root = root.splittingLeaf(id: original, direction: .vertical)
        XCTAssertEqual(root.leafCount, 2)
        XCTAssertTrue(root.canMerge(leafID: root.firstLeafID))
        if case .split(let split) = root {
            root = root.updatingSplitRatio(id: split.id, ratio: 0.01)
            if case .split(let changed) = root { XCTAssertEqual(changed.ratio, 0.2) }
        }
        root = root.mergingLeaf(id: root.firstLeafID)
        XCTAssertEqual(root.leafCount, 1)
    }

    func testFourZonePresetUsesFourLeavesAndRoundTrips() throws {
        let scene = LightScene(name: "四区", layout: .four)
        XCTAssertEqual(scene.leafCount, 4)
        XCTAssertEqual(scene.rootNode.presetLayout, .four)
        let decoded = try JSONDecoder().decode(LightScene.self, from: JSONEncoder().encode(scene))
        XCTAssertEqual(decoded, scene)
    }

    func testLegacyLightingSceneMigratesToTree() throws {
        let id = UUID()
        let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0))
        let json = "{\"id\":\"\(id.uuidString)\",\"name\":\"旧场景\",\"layout\":\"leftRight\",\"zones\":[{\"id\":\"\(UUID().uuidString)\",\"colorARGB\":4294967295,\"intensity\":1,\"softness\":0.2},{\"id\":\"\(UUID().uuidString)\",\"colorARGB\":4294967295,\"intensity\":1,\"softness\":0.2}],\"screenBrightness\":0.9,\"updatedAt\":\"\(date)\"}"
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let scene = try decoder.decode(LightScene.self, from: Data(json.utf8))
        XCTAssertEqual(scene.leafCount, 2)
        XCTAssertEqual(scene.rootNode.presetLayout, .leftRight)
    }

    func testVideoStorageEstimateHasSafetyFloor() {
        XCTAssertEqual(VideoProcessor.estimatedRequiredBytes(sourceBytes: 1), 256 * 1_024 * 1_024 + 2)
        XCTAssertEqual(VideoProcessor.estimatedRequiredBytes(sourceBytes: 200_000_000), 400_000_000 + 256 * 1_024 * 1_024)
    }

    func testUnknownTotalDownloadStillReportsTransferredBytes() {
        let meter = DownloadProgressMeter(total: 0)
        let report = meter.update(completed: 2_500_000, total: 0)
        XCTAssertEqual(report.completed, 2_500_000)
        XCTAssertEqual(report.total, 0)
        XCTAssertNil(report.eta)
    }

    func testDownloadTaskIdentityIncludesSourceCamera() {
        let asset = PhotoAsset(handle: 7, name: "DSC_0001.JPG", size: 42, format: 0x3801, capturedAt: .now)
        let first = DownloadTaskModel(asset: asset, sourceID: "wifi|camera-a")
        let second = DownloadTaskModel(asset: asset, sourceID: "usb|camera-b")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.sourceID, second.sourceID)
    }

    func testBundledVisualResourcesAreAvailable() {
        XCTAssertNotNil(UIImage(named: "CameraBridgeLogo"))
        XCTAssertNotNil(Bundle.main.url(forResource: "AlibabaPuHuiTi-2-45-Light", withExtension: "otf"))
        XCTAssertNotNil(Bundle.main.url(forResource: "wm_nikon", withExtension: "png"))
        XCTAssertNotNil(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    }
}
