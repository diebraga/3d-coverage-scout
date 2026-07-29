import XCTest
import simd
@testable import CoverageScout

final class VoxelGridTests: XCTestCase {
    func makeObservation(direction: SIMD3<Float>, distance: Float = 1.0, angle: Float = 10) -> Observation {
        Observation(viewDirection: simd_normalize(direction), distance: distance, angleToNormalDegrees: angle)
    }

    func test_emptyGrid_qualityIsZero() {
        let grid = VoxelGrid()
        XCTAssertEqual(grid.qualityPercentage, 0)
    }

    func test_coordinate_bucketsNearbyPositionsTogether() {
        let a = VoxelGrid.coordinate(for: SIMD3(0.01, 0.01, 0.01))
        let b = VoxelGrid.coordinate(for: SIMD3(0.05, 0.05, 0.05))
        XCTAssertEqual(a, b)
    }

    func test_coordinate_separatesFarPositions() {
        let a = VoxelGrid.coordinate(for: SIMD3(0, 0, 0))
        let b = VoxelGrid.coordinate(for: SIMD3(1, 0, 0))
        XCTAssertNotEqual(a, b)
    }

    func test_recordSingleValidObservation_classifiesRed() {
        let grid = VoxelGrid()
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: SIMD3(0, 0, 0))
        XCTAssertEqual(grid.classification(at: SIMD3(0, 0, 0)), .red)
        XCTAssertEqual(grid.redCount, 1)
        XCTAssertEqual(grid.greenCount, 0)
    }

    func test_recordTwoWideAngleObservations_classifiesGreenAndUpdatesCounts() {
        let grid = VoxelGrid()
        let position = SIMD3<Float>(0, 0, 0)
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: position)
        grid.recordObservation(makeObservation(direction: SIMD3(1, 0, 1)), at: position)
        XCTAssertEqual(grid.classification(at: position), .green)
        XCTAssertEqual(grid.redCount, 0)
        XCTAssertEqual(grid.greenCount, 1)
    }

    func test_qualityPercentage_reflectsGreenOverGreenPlusRed() {
        let grid = VoxelGrid()
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: SIMD3(0, 0, 0))
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: SIMD3(1, 0, 0))
        grid.recordObservation(makeObservation(direction: SIMD3(1, 0, 1)), at: SIMD3(1, 0, 0))
        XCTAssertEqual(grid.redCount, 1)
        XCTAssertEqual(grid.greenCount, 1)
        XCTAssertEqual(grid.qualityPercentage, 50.0, accuracy: 0.01)
    }

    func test_unobservedPosition_isGray() {
        let grid = VoxelGrid()
        XCTAssertEqual(grid.classification(at: SIMD3(9, 9, 9)), .gray)
    }

    func test_incompleteSamples_returnsRedVoxel() {
        let grid = VoxelGrid()
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: SIMD3(0, 0, 0))

        let samples = grid.incompleteSamples(limit: 10, near: SIMD3(0, 0, 0))

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].coverage, .red)
    }

    func test_incompleteSamples_excludesGreenVoxel() {
        let grid = VoxelGrid()
        let position = SIMD3<Float>(0, 0, 0)
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: position)
        grid.recordObservation(makeObservation(direction: SIMD3(1, 0, 1)), at: position)

        XCTAssertTrue(grid.incompleteSamples(limit: 10, near: position).isEmpty)
    }

    func test_incompleteSamples_enforcesLimitAndSortsNearestFirst() {
        let grid = VoxelGrid()
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: SIMD3(2, 0, 0))
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: SIMD3(0, 0, 0))

        let samples = grid.incompleteSamples(limit: 1, near: SIMD3(0, 0, 0))

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].coordinate, VoxelGrid.coordinate(for: SIMD3(0, 0, 0)))
    }

    func test_manyRepeatedObservations_staysRedAndCountsStayCorrect() {
        // Regression test for a real device crash: recording unbounded observations
        // at one voxel made CoverageClassifier.classify's O(n^2) angle check blow up
        // on the main thread until iOS's watchdog killed the app. This simulates a
        // long dwell near one spot (100 same-angle observations, never wide enough
        // to go green) and asserts the classification and counts stay correct —
        // the array itself is capped internally and not directly observable here.
        let grid = VoxelGrid()
        let position = SIMD3<Float>(0, 0, 0)
        for _ in 0..<100 {
            grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: position)
        }
        XCTAssertEqual(grid.classification(at: position), .red)
        XCTAssertEqual(grid.redCount, 1)
        XCTAssertEqual(grid.greenCount, 0)
    }

    func test_onceGreen_furtherObservationsAreIgnored() {
        let grid = VoxelGrid()
        let position = SIMD3<Float>(0, 0, 0)
        grid.recordObservation(makeObservation(direction: SIMD3(0, 0, 1)), at: position)
        grid.recordObservation(makeObservation(direction: SIMD3(1, 0, 1)), at: position)
        XCTAssertEqual(grid.greenCount, 1)

        for _ in 0..<20 {
            grid.recordObservation(makeObservation(direction: SIMD3(0, 1, 0)), at: position)
        }

        XCTAssertEqual(grid.classification(at: position), .green)
        XCTAssertEqual(grid.greenCount, 1)
        XCTAssertEqual(grid.redCount, 0)
    }

    func test_incompleteSamples_returnsGrayVoxel() {
        let grid = VoxelGrid()
        let position = SIMD3<Float>(0, 0, 0)
        grid.recordObservation(
            makeObservation(direction: SIMD3(0, 0, 1), distance: CoverageClassifier.maxValidDistance + 1),
            at: position
        )

        let samples = grid.incompleteSamples(limit: 10, near: position)

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].coordinate, VoxelGrid.coordinate(for: position))
        XCTAssertEqual(samples[0].coverage, .gray)
        XCTAssertEqual(grid.redCount, 0)
        XCTAssertEqual(grid.greenCount, 0)
    }
}
