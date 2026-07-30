import ARKit
import XCTest
@testable import CoverageScout

final class ARFrameMetadataSnapshotTests: XCTestCase {
    func test_matrix4x4SerializesRowsWithTranslationInLastColumn() {
        let matrix = simd_float4x4(
            SIMD4<Float>(1, 2, 3, 4),
            SIMD4<Float>(5, 6, 7, 8),
            SIMD4<Float>(9, 10, 11, 12),
            SIMD4<Float>(13, 14, 15, 16)
        )

        XCTAssertEqual(ARFrameMetadataSnapshot.rows(from: matrix), [
            [1, 5, 9, 13],
            [2, 6, 10, 14],
            [3, 7, 11, 15],
            [4, 8, 12, 16]
        ])
    }

    func test_matrix3x3SerializesRows() {
        let matrix = simd_float3x3(
            SIMD3<Float>(1, 2, 3),
            SIMD3<Float>(4, 5, 6),
            SIMD3<Float>(7, 8, 9)
        )

        XCTAssertEqual(ARFrameMetadataSnapshot.rows(from: matrix), [
            [1, 4, 7],
            [2, 5, 8],
            [3, 6, 9]
        ])
    }

    func test_trackingStateStringsAreStableForPipelineConsumers() {
        XCTAssertEqual(ARFrameMetadataSnapshot.description(for: ARCamera.TrackingState.normal), "normal")
        XCTAssertEqual(ARFrameMetadataSnapshot.description(for: ARCamera.TrackingState.limited(.excessiveMotion)), "limited_excessive_motion")
        XCTAssertEqual(ARFrameMetadataSnapshot.description(for: ARCamera.TrackingState.limited(.insufficientFeatures)), "limited_insufficient_features")
        XCTAssertEqual(ARFrameMetadataSnapshot.description(for: ARCamera.TrackingState.notAvailable), "not_available")
    }
}

