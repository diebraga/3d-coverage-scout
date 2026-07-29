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
}
