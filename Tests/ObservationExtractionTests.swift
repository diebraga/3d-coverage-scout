import XCTest
@testable import CoverageScout

final class ObservationExtractionTests: XCTestCase {
    func test_cameraDirectlyAboveSurface_zeroAngle() {
        let obs = ObservationExtraction.observation(
            surfacePosition: SIMD3(0, 0, 0),
            surfaceNormal: SIMD3(0, 1, 0),
            cameraPosition: SIMD3(0, 1, 0)
        )
        XCTAssertEqual(obs.distance, 1.0, accuracy: 0.001)
        XCTAssertEqual(obs.angleToNormalDegrees, 0, accuracy: 0.1)
    }

    func test_cameraAtGrazingAngle_90Degrees() {
        let obs = ObservationExtraction.observation(
            surfacePosition: SIMD3(0, 0, 0),
            surfaceNormal: SIMD3(0, 1, 0),
            cameraPosition: SIMD3(1, 0, 0)
        )
        XCTAssertEqual(obs.angleToNormalDegrees, 90, accuracy: 0.1)
    }

    func test_viewDirectionPointsFromSurfaceToCamera() {
        let obs = ObservationExtraction.observation(
            surfacePosition: SIMD3(0, 0, 0),
            surfaceNormal: SIMD3(0, 0, 1),
            cameraPosition: SIMD3(0, 0, 2)
        )
        XCTAssertEqual(obs.viewDirection, SIMD3(0, 0, 1))
    }
}
