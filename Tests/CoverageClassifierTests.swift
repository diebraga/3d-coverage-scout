import XCTest
import simd
@testable import CoverageScout

final class CoverageClassifierTests: XCTestCase {
    func makeObservation(direction: SIMD3<Float>, distance: Float, angle: Float) -> Observation {
        Observation(viewDirection: simd_normalize(direction), distance: distance, angleToNormalDegrees: angle)
    }

    func test_noObservations_isGray() {
        XCTAssertEqual(CoverageClassifier.classify([]), .gray)
    }

    func test_singleValidObservation_isRed() {
        let obs = makeObservation(direction: SIMD3(0, 0, 1), distance: 1.0, angle: 10)
        XCTAssertEqual(CoverageClassifier.classify([obs]), .red)
    }

    func test_onlyInvalidObservations_isGray() {
        let tooFar = makeObservation(direction: SIMD3(0, 0, 1), distance: 5.0, angle: 10)
        let tooGrazing = makeObservation(direction: SIMD3(1, 0, 0), distance: 1.0, angle: 80)
        XCTAssertEqual(CoverageClassifier.classify([tooFar, tooGrazing]), .gray)
    }

    func test_twoValidObservationsCloseAngles_isRed() {
        let a = makeObservation(direction: SIMD3(0, 0, 1), distance: 1.0, angle: 10)
        let b = makeObservation(direction: SIMD3(0.05, 0, 1), distance: 1.0, angle: 12)
        XCTAssertEqual(CoverageClassifier.classify([a, b]), .red)
    }

    func test_twoValidObservationsWideAngles_isGreen() {
        let a = makeObservation(direction: SIMD3(0, 0, 1), distance: 1.0, angle: 10)
        let b = makeObservation(direction: SIMD3(1, 0, 1), distance: 1.0, angle: 10)
        XCTAssertEqual(CoverageClassifier.classify([a, b]), .green)
    }

    func test_angularSeparation_orthogonalVectors_is90Degrees() {
        let separation = CoverageClassifier.angularSeparationDegrees(SIMD3(1, 0, 0), SIMD3(0, 1, 0))
        XCTAssertEqual(separation, 90, accuracy: 0.01)
    }

    func test_isValid_boundaryDistance_isInclusive() {
        let atMin = Observation(viewDirection: SIMD3(0, 0, 1), distance: 0.3, angleToNormalDegrees: 0)
        let atMax = Observation(viewDirection: SIMD3(0, 0, 1), distance: 3.0, angleToNormalDegrees: 60)
        XCTAssertTrue(CoverageClassifier.isValid(atMin))
        XCTAssertTrue(CoverageClassifier.isValid(atMax))
    }

    func test_isValid_justOutsideBounds_isFalse() {
        let tooClose = Observation(viewDirection: SIMD3(0, 0, 1), distance: 0.29, angleToNormalDegrees: 0)
        let tooSteep = Observation(viewDirection: SIMD3(0, 0, 1), distance: 1.0, angleToNormalDegrees: 60.1)
        XCTAssertFalse(CoverageClassifier.isValid(tooClose))
        XCTAssertFalse(CoverageClassifier.isValid(tooSteep))
    }

    // MARK: - Confidence (drives the gradual fog reveal)

    func test_confidence_noObservations_isZero() {
        XCTAssertEqual(CoverageClassifier.confidence([]), 0)
    }

    func test_confidence_onlyInvalidObservations_isZero() {
        let tooFar = makeObservation(direction: SIMD3(0, 0, 1), distance: 5.0, angle: 10)
        let tooGrazing = makeObservation(direction: SIMD3(1, 0, 0), distance: 1.0, angle: 80)
        XCTAssertEqual(CoverageClassifier.confidence([tooFar, tooGrazing]), 0)
    }

    func test_confidence_singleValidObservation_isZero() {
        // One viewpoint has no angular separation yet, so no parallax has been
        // established — nothing to be confident about.
        let single = makeObservation(direction: SIMD3(0, 0, 1), distance: 1.0, angle: 10)
        XCTAssertEqual(CoverageClassifier.confidence([single]), 0)
    }

    func test_confidence_partialSeparation_isBetweenZeroAndOne() {
        // ~7.5 degrees apart: half of the 15 degree confirmed threshold.
        let a = makeObservation(direction: SIMD3(0, 0, 1), distance: 1.0, angle: 10)
        let b = makeObservation(direction: SIMD3(0.1317, 0, 1), distance: 1.0, angle: 10)

        let score = CoverageClassifier.confidence([a, b])

        XCTAssertGreaterThan(score, 0.4)
        XCTAssertLessThan(score, 0.6)
    }

    func test_confidence_atConfirmedThreshold_isOne() {
        let a = makeObservation(direction: SIMD3(0, 0, 1), distance: 1.0, angle: 10)
        let b = makeObservation(direction: SIMD3(1, 0, 1), distance: 1.0, angle: 10)

        XCTAssertEqual(CoverageClassifier.confidence([a, b]), 1.0)
        // Stays consistent with the discrete classifier by construction.
        XCTAssertEqual(CoverageClassifier.classify([a, b]), .green)
    }

    func test_confidence_neverExceedsOne() {
        let a = makeObservation(direction: SIMD3(0, 0, 1), distance: 1.0, angle: 10)
        let opposite = makeObservation(direction: SIMD3(0, 0, -1), distance: 1.0, angle: 10)
        XCTAssertEqual(CoverageClassifier.confidence([a, opposite]), 1.0)
    }

    func test_confidence_usesWidestPairNotMostRecent() {
        let a = makeObservation(direction: SIMD3(0, 0, 1), distance: 1.0, angle: 10)
        let wide = makeObservation(direction: SIMD3(1, 0, 1), distance: 1.0, angle: 10)
        let nearDuplicate = makeObservation(direction: SIMD3(0.01, 0, 1), distance: 1.0, angle: 10)

        // The last-added observation is nearly identical to the first, but the
        // widest pair in the set already crossed the threshold.
        XCTAssertEqual(CoverageClassifier.confidence([a, wide, nearDuplicate]), 1.0)
    }
}
