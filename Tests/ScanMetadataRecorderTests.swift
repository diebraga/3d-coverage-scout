import XCTest
@testable import CoverageScout

final class ScanMetadataRecorderTests: XCTestCase {
    func test_encodedDocumentUsesExpectedJSONKeysAndFrameOrder() throws {
        let recorder = ScanMetadataRecorder()
        let createdAt = Date(timeIntervalSince1970: 1_785_440_365)

        recorder.start(
            videoFilename: "scan.mov",
            width: 1920,
            height: 1080,
            frameRate: 30,
            createdAt: createdAt
        )
        recorder.append(frame: frame(videoTimestamp: 0.0, arkitTimestamp: 10.0, scanQuality: 12.5))
        recorder.append(frame: frame(videoTimestamp: 0.5, arkitTimestamp: 10.5, scanQuality: 25.0))

        let data = try recorder.encodedDocument(
            durationSeconds: 0.5,
            scanQualityFinal: 25.0,
            sceneDepthEnabled: true
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let video = try XCTUnwrap(object["video"] as? [String: Any])
        let capture = try XCTUnwrap(object["capture"] as? [String: Any])
        let frames = try XCTUnwrap(object["frames"] as? [[String: Any]])

        XCTAssertEqual(object["schema_version"] as? Int, 1)
        XCTAssertEqual(object["app"] as? String, "Coverage Scout")
        XCTAssertEqual(object["arkit_world_units"] as? String, "meters")
        XCTAssertEqual(video["filename"] as? String, "scan.mov")
        XCTAssertEqual(video["width"] as? Int, 1920)
        XCTAssertEqual(video["height"] as? Int, 1080)
        XCTAssertEqual(video["frame_rate"] as? Int, 30)
        XCTAssertEqual(capture["device_supports_lidar"] as? Bool, true)
        XCTAssertEqual(capture["scene_reconstruction"] as? String, "mesh")
        XCTAssertEqual(capture["scene_depth_enabled"] as? Bool, true)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0]["video_timestamp_seconds"] as? Double, 0.0)
        XCTAssertEqual(frames[1]["video_timestamp_seconds"] as? Double, 0.5)
    }

    func test_finishPreservesMatrixShapes() {
        let recorder = ScanMetadataRecorder()
        recorder.start(videoFilename: "scan.mov", width: 64, height: 64, frameRate: 30, createdAt: Date(timeIntervalSince1970: 0))
        recorder.append(frame: frame(videoTimestamp: 0, arkitTimestamp: 1, scanQuality: 0))

        let document = recorder.finish(durationSeconds: 0, scanQualityFinal: 0, sceneDepthEnabled: false)
        let sample = document.frames[0]

        XCTAssertEqual(sample.cameraTransform.count, 4)
        XCTAssertTrue(sample.cameraTransform.allSatisfy { $0.count == 4 })
        XCTAssertEqual(sample.intrinsics.count, 3)
        XCTAssertTrue(sample.intrinsics.allSatisfy { $0.count == 3 })
        XCTAssertEqual(sample.imageResolution, [64, 64])
    }

    private func frame(videoTimestamp: Double, arkitTimestamp: Double, scanQuality: Double) -> ScanFrameMetadata {
        ScanFrameMetadata(
            videoTimestampSeconds: videoTimestamp,
            arkitTimestampSeconds: arkitTimestamp,
            cameraTransform: [
                [1, 0, 0, 0.1],
                [0, 1, 0, 0.2],
                [0, 0, 1, 0.3],
                [0, 0, 0, 1]
            ],
            intrinsics: [
                [100, 0, 32],
                [0, 100, 32],
                [0, 0, 1]
            ],
            imageResolution: [64, 64],
            trackingState: "normal",
            scanQuality: scanQuality
        )
    }
}

