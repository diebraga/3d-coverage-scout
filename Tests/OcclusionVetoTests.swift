import XCTest
import simd
@testable import CoverageScout

final class OcclusionVetoTests: XCTestCase {
    // MARK: - isWithinCenterCone

    func test_isWithinCenterCone_sameDirection_isTrue() {
        let result = OcclusionVeto.isWithinCenterCone(
            vertexDirection: SIMD3(0, 0, 1),
            cameraForward: SIMD3(0, 0, 1),
            halfAngleDegrees: 25
        )
        XCTAssertTrue(result)
    }

    func test_isWithinCenterCone_exactlyAtBoundary_isTrue() {
        let angle: Float = 25 * .pi / 180
        let direction = SIMD3<Float>(sin(angle), 0, cos(angle))
        let result = OcclusionVeto.isWithinCenterCone(
            vertexDirection: direction,
            cameraForward: SIMD3(0, 0, 1),
            halfAngleDegrees: 25
        )
        XCTAssertTrue(result)
    }

    func test_isWithinCenterCone_justPastBoundary_isFalse() {
        let angle: Float = 25.5 * .pi / 180
        let direction = SIMD3<Float>(sin(angle), 0, cos(angle))
        let result = OcclusionVeto.isWithinCenterCone(
            vertexDirection: direction,
            cameraForward: SIMD3(0, 0, 1),
            halfAngleDegrees: 25
        )
        XCTAssertFalse(result)
    }

    func test_isWithinCenterCone_oppositeDirection_isFalse() {
        let result = OcclusionVeto.isWithinCenterCone(
            vertexDirection: SIMD3(0, 0, -1),
            cameraForward: SIMD3(0, 0, 1),
            halfAngleDegrees: 25
        )
        XCTAssertFalse(result)
    }

    func test_isWithinCenterCone_zeroLengthDirection_isFalse() {
        let result = OcclusionVeto.isWithinCenterCone(
            vertexDirection: SIMD3(0, 0, 0),
            cameraForward: SIMD3(0, 0, 1),
            halfAngleDegrees: 25
        )
        XCTAssertFalse(result)
    }

    // MARK: - isBlocked

    func test_isBlocked_liveDepthClearlyCloser_isTrue() {
        XCTAssertTrue(OcclusionVeto.isBlocked(liveDepth: 0.5, vertexDistance: 1.0, marginMeters: 0.05))
    }

    func test_isBlocked_liveDepthEqualToVertex_isFalse() {
        XCTAssertFalse(OcclusionVeto.isBlocked(liveDepth: 1.0, vertexDistance: 1.0, marginMeters: 0.05))
    }

    func test_isBlocked_liveDepthWithinMargin_isFalse() {
        // 0.03m closer, but margin is 0.05m — within sensor-noise tolerance.
        XCTAssertFalse(OcclusionVeto.isBlocked(liveDepth: 0.97, vertexDistance: 1.0, marginMeters: 0.05))
    }

    func test_isBlocked_liveDepthJustPastMargin_isTrue() {
        XCTAssertTrue(OcclusionVeto.isBlocked(liveDepth: 0.94, vertexDistance: 1.0, marginMeters: 0.05))
    }

    func test_isBlocked_liveDepthFartherBehindVertex_isFalse() {
        XCTAssertFalse(OcclusionVeto.isBlocked(liveDepth: 2.0, vertexDistance: 1.0, marginMeters: 0.05))
    }

    func test_isBlocked_zeroLiveDepth_isFalse() {
        // ARKit reports 0 for invalid/unmeasured depth samples — must not be
        // treated as "something extremely close."
        XCTAssertFalse(OcclusionVeto.isBlocked(liveDepth: 0, vertexDistance: 1.0, marginMeters: 0.05))
    }

    func test_isBlocked_nanLiveDepth_isFalse() {
        XCTAssertFalse(OcclusionVeto.isBlocked(liveDepth: .nan, vertexDistance: 1.0, marginMeters: 0.05))
    }

    // MARK: - depthPixel

    func test_depthPixel_projectsCenterPointIntoDepthMap() {
        var intrinsics = simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1))
        intrinsics[0, 0] = 100
        intrinsics[1, 1] = 100
        intrinsics[2, 0] = 50
        intrinsics[2, 1] = 40

        let sample = OcclusionVeto.depthPixel(
            for: SIMD3<Float>(0, 0, -2),
            cameraTransform: matrix_identity_float4x4,
            cameraIntrinsics: intrinsics,
            cameraImageResolution: CGSize(width: 100, height: 80),
            depthMapSize: CGSize(width: 50, height: 40)
        )

        guard let sample else {
            XCTFail("Expected projected depth pixel")
            return
        }
        XCTAssertEqual(sample.x, 25)
        XCTAssertEqual(sample.y, 20)
        XCTAssertEqual(sample.vertexDistance, 2, accuracy: 0.001)
    }

    func test_depthPixel_returnsNilForPointBehindCamera() {
        let sample = OcclusionVeto.depthPixel(
            for: SIMD3<Float>(0, 0, 2),
            cameraTransform: matrix_identity_float4x4,
            cameraIntrinsics: simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1)),
            cameraImageResolution: CGSize(width: 100, height: 80),
            depthMapSize: CGSize(width: 50, height: 40)
        )

        XCTAssertNil(sample)
    }

    func test_depthPixel_returnsNilForPointOutsideDepthMap() {
        var intrinsics = simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1))
        intrinsics[0, 0] = 100
        intrinsics[1, 1] = 100
        intrinsics[2, 0] = 50
        intrinsics[2, 1] = 40

        let sample = OcclusionVeto.depthPixel(
            for: SIMD3<Float>(5, 0, -1),
            cameraTransform: matrix_identity_float4x4,
            cameraIntrinsics: intrinsics,
            cameraImageResolution: CGSize(width: 100, height: 80),
            depthMapSize: CGSize(width: 50, height: 40)
        )

        XCTAssertNil(sample)
    }
}
