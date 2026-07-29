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

    /// Continuous 0...1 version of `classify`, driving the gradual fog reveal.
    /// Reaches exactly 1.0 at the same `minAngularSeparationDegrees` threshold
    /// `classify` uses for `.green`, so the two can never disagree about when a
    /// voxel is confirmed.
    ///
    /// Callers must cache the result rather than recomputing it per rendered
    /// frame — this is O(n^2) in the observation count, which is what previously
    /// blocked the main thread badly enough for iOS to kill the app.
    static func confidence(_ observations: [Observation]) -> Float {
        let valid = observations.filter(isValid)
        guard valid.count >= 2 else { return 0 }

        var widestSeparation: Float = 0
        for i in 0..<valid.count {
            for j in (i + 1)..<valid.count {
                let separation = angularSeparationDegrees(valid[i].viewDirection, valid[j].viewDirection)
                if separation >= minAngularSeparationDegrees { return 1 }
                widestSeparation = max(widestSeparation, separation)
            }
        }
        return widestSeparation / minAngularSeparationDegrees
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
