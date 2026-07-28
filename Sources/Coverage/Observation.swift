import simd

enum VoxelCoverage: Equatable {
    case gray
    case red
    case green
}

struct Observation: Equatable {
    let viewDirection: SIMD3<Float> // unit vector, surface point -> camera, world space
    let distance: Float             // meters
    let angleToNormalDegrees: Float // 0 = camera straight-on to the surface
}
