import simd

struct VoxelCoordinate: Hashable {
    let x: Int32
    let y: Int32
    let z: Int32
}

struct VoxelOverlaySample: Hashable {
    let coordinate: VoxelCoordinate
    let center: SIMD3<Float>
    let coverage: VoxelCoverage
}

final class VoxelGrid {
    static let voxelSize: Float = 0.1

    private var observationsByVoxel: [VoxelCoordinate: [Observation]] = [:]
    private var classificationByVoxel: [VoxelCoordinate: VoxelCoverage] = [:]
    private(set) var greenCount = 0
    private(set) var redCount = 0

    static func coordinate(for worldPosition: SIMD3<Float>) -> VoxelCoordinate {
        VoxelCoordinate(
            x: Int32(floor(worldPosition.x / voxelSize)),
            y: Int32(floor(worldPosition.y / voxelSize)),
            z: Int32(floor(worldPosition.z / voxelSize))
        )
    }

    func recordObservation(_ observation: Observation, at worldPosition: SIMD3<Float>) {
        let coordinate = Self.coordinate(for: worldPosition)
        var observations = observationsByVoxel[coordinate] ?? []
        observations.append(observation)
        observationsByVoxel[coordinate] = observations

        let oldClassification = classificationByVoxel[coordinate] ?? .gray
        let newClassification = CoverageClassifier.classify(observations)
        classificationByVoxel[coordinate] = newClassification
        guard newClassification != oldClassification else { return }

        if oldClassification == .green { greenCount -= 1 }
        if oldClassification == .red { redCount -= 1 }
        if newClassification == .green { greenCount += 1 }
        if newClassification == .red { redCount += 1 }
    }

    func classification(at worldPosition: SIMD3<Float>) -> VoxelCoverage {
        classificationByVoxel[Self.coordinate(for: worldPosition)] ?? .gray
    }

    func incompleteSamples(limit: Int, near cameraPosition: SIMD3<Float>) -> [VoxelOverlaySample] {
        guard limit > 0 else { return [] }

        return classificationByVoxel.compactMap { coordinate, coverage in
            guard coverage != .green else { return nil }
            return VoxelOverlaySample(
                coordinate: coordinate,
                center: Self.center(for: coordinate),
                coverage: coverage
            )
        }
        .sorted {
            simd_distance_squared($0.center, cameraPosition) < simd_distance_squared($1.center, cameraPosition)
        }
        .prefix(limit)
        .map { $0 }
    }

    var qualityPercentage: Double {
        let total = greenCount + redCount
        guard total > 0 else { return 0 }
        return Double(greenCount) / Double(total) * 100
    }

    private static func center(for coordinate: VoxelCoordinate) -> SIMD3<Float> {
        SIMD3<Float>(
            (Float(coordinate.x) + 0.5) * voxelSize,
            (Float(coordinate.y) + 0.5) * voxelSize,
            (Float(coordinate.z) + 0.5) * voxelSize
        )
    }
}
