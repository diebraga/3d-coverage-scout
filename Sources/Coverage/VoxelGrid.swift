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

/// Visual-only mapping for the live preview. Confirmed surfaces fade completely
/// back to the normal camera image.
enum ScanPreviewStyle {
    static let maximumOpacity: Float = 0.55

    static func opacity(for confidence: Float) -> Float {
        let remaining = 1 - min(max(confidence, 0), 1)
        return maximumOpacity * remaining.squareRoot().squareRoot()
    }
}

final class VoxelGrid {
    static let voxelSize: Float = 0.1

    // Confirmed root cause of a real device crash (watchdog SIGKILL,
    // 0x8BADF00D): CoverageClassifier.classify is O(n^2) in a voxel's
    // observation count, and this array previously grew unbounded for the
    // whole session — a voxel the camera lingers near or revisits
    // accumulates dozens of observations, and that quadratic cost on the
    // main thread eventually blocks it long enough for iOS to kill the app.
    // 8 samples is far more than classify() needs to find a wide-angle pair.
    private static let maxObservationsPerVoxel = 8

    private var observationsByVoxel: [VoxelCoordinate: [Observation]] = [:]
    private var classificationByVoxel: [VoxelCoordinate: VoxelCoverage] = [:]
    // Cached so rendering can read a plain float per vertex instead of re-running
    // CoverageClassifier.confidence's O(n^2) scan on every mesh rebuild.
    private var confidenceByVoxel: [VoxelCoordinate: Float] = [:]
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
        let oldClassification = classificationByVoxel[coordinate] ?? .gray

        // Once green, more observations can't add information (classify()
        // only needs ANY wide-angle pair, which already exists) — skipping
        // this also caps the array's lifetime growth at the point it stops
        // being useful, not just its size.
        guard oldClassification != .green else { return }

        var observations = observationsByVoxel[coordinate] ?? []
        if observations.count >= Self.maxObservationsPerVoxel {
            observations.removeFirst()
        }
        observations.append(observation)
        observationsByVoxel[coordinate] = observations

        let newClassification = CoverageClassifier.classify(observations)
        classificationByVoxel[coordinate] = newClassification
        confidenceByVoxel[coordinate] = CoverageClassifier.confidence(observations)
        guard newClassification != oldClassification else { return }

        if oldClassification == .red { redCount -= 1 }
        if newClassification == .green { greenCount += 1 }
        if newClassification == .red { redCount += 1 }
    }

    func classification(at worldPosition: SIMD3<Float>) -> VoxelCoverage {
        classificationByVoxel[Self.coordinate(for: worldPosition)] ?? .gray
    }

    /// 0 = never observed (fully fogged), 1 = confirmed (fully revealed).
    ///
    /// Falls back to checking the immediate neighborhood if the exact voxel has
    /// no data. ARKit's tracked camera pose can shift slightly after a brief
    /// tracking-quality dip (e.g. recovering from "Too little detail"), which
    /// can move a physical spot's computed voxel by a cell even though nothing
    /// about the real scan changed — without this, that reads as "never
    /// scanned" and previously-revealed surfaces would re-fog. The exact-match
    /// case (the overwhelming majority of lookups) stays a single O(1) lookup;
    /// the neighborhood scan only runs on a miss.
    func confidence(at worldPosition: SIMD3<Float>) -> Float {
        let exact = Self.coordinate(for: worldPosition)
        if let value = confidenceByVoxel[exact] { return value }

        var best: Float = 0
        for dx: Int32 in -1...1 {
            for dy: Int32 in -1...1 {
                for dz: Int32 in -1...1 {
                    guard dx != 0 || dy != 0 || dz != 0 else { continue }
                    let neighbor = VoxelCoordinate(x: exact.x + dx, y: exact.y + dy, z: exact.z + dz)
                    if let value = confidenceByVoxel[neighbor] {
                        best = max(best, value)
                    }
                }
            }
        }
        return best
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
