import simd

enum CoverageClassifier {
    static let minValidDistance: Float = 0.3
    static let maxValidDistance: Float = 3.0
    static let maxValidAngleDegrees: Float = 60.0
    static let minAngularSeparationDegrees: Float = 15.0

    static func isValid(_ observation: Observation) -> Bool {
        observation.distance >= minValidDistance &&
        observation.distance <= maxValidDistance &&
        observation.angleToNormalDegrees <= maxValidAngleDegrees
    }

    static func angularSeparationDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let dot = simd_clamp(simd_dot(simd_normalize(a), simd_normalize(b)), -1, 1)
        return acos(dot) * 180 / .pi
    }

    static func classify(_ observations: [Observation]) -> VoxelCoverage {
        let valid = observations.filter(isValid)
        guard !valid.isEmpty else { return .gray }
        for i in 0..<valid.count {
            for j in (i + 1)..<valid.count {
                if angularSeparationDegrees(valid[i].viewDirection, valid[j].viewDirection) >= minAngularSeparationDegrees {
                    return .green
                }
            }
        }
        return .red
    }
}
