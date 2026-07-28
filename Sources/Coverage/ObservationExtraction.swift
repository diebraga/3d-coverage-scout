import simd

enum ObservationExtraction {
    static func observation(surfacePosition: SIMD3<Float>, surfaceNormal: SIMD3<Float>, cameraPosition: SIMD3<Float>) -> Observation {
        let toCamera = cameraPosition - surfacePosition
        let distance = simd_length(toCamera)
        let viewDirection = distance > 0 ? toCamera / distance : SIMD3<Float>(0, 0, 0)
        let dot = simd_clamp(simd_dot(simd_normalize(surfaceNormal), viewDirection), -1, 1)
        let angleToNormalDegrees = acos(dot) * 180 / .pi
        return Observation(viewDirection: viewDirection, distance: distance, angleToNormalDegrees: angleToNormalDegrees)
    }
}
