import simd

/// Pure math backing the live occlusion veto — deliberately free of ARKit
/// types so it's testable on Simulator. The ARKit/CVPixelBuffer glue that
/// calls these lives in ARSessionManager, which can only be verified on a
/// physical LiDAR device.
enum OcclusionVeto {
    /// Whether `vertexDirection` (camera -> vertex) falls within
    /// `halfAngleDegrees` of `cameraForward` — the cheap first-pass filter
    /// that restricts the live-depth check to the center of view.
    static func isWithinCenterCone(vertexDirection: SIMD3<Float>, cameraForward: SIMD3<Float>, halfAngleDegrees: Float) -> Bool {
        guard simd_length(vertexDirection) > 0 else { return false }
        let dot = simd_clamp(simd_dot(simd_normalize(vertexDirection), simd_normalize(cameraForward)), -1, 1)
        let angleDegrees = acos(dot) * 180 / .pi
        return angleDegrees <= halfAngleDegrees
    }

    /// Whether a live depth reading indicates something is currently between
    /// the camera and a vertex at `vertexDistance`, beyond `marginMeters` of
    /// tolerance for sensor noise. `liveDepth <= 0` or non-finite means an
    /// invalid/unmeasured sample, never treated as "something is there."
    static func isBlocked(liveDepth: Float, vertexDistance: Float, marginMeters: Float) -> Bool {
        guard liveDepth.isFinite, liveDepth > 0 else { return false }
        return liveDepth < vertexDistance - marginMeters
    }
}
