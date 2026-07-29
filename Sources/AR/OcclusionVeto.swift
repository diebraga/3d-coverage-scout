import CoreGraphics
import simd

/// Pure math backing the live occlusion veto — deliberately free of ARKit
/// types so it's testable on Simulator. The ARKit/CVPixelBuffer glue that
/// calls these lives in ARSessionManager, which can only be verified on a
/// physical LiDAR device.
enum OcclusionVeto {
    struct DepthPixel {
        let x: Int
        let y: Int
        let vertexDistance: Float
    }

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

    static func depthPixel(
        for worldPosition: SIMD3<Float>,
        cameraTransform: simd_float4x4,
        cameraIntrinsics: simd_float3x3,
        cameraImageResolution: CGSize,
        depthMapSize: CGSize
    ) -> DepthPixel? {
        let cameraSpace4 = simd_inverse(cameraTransform) * SIMD4<Float>(worldPosition, 1)
        let depth = -cameraSpace4.z
        guard depth.isFinite, depth > 0 else { return nil }

        let xScale = Float(depthMapSize.width / cameraImageResolution.width)
        let yScale = Float(depthMapSize.height / cameraImageResolution.height)
        let fx = cameraIntrinsics[0, 0] * xScale
        let fy = cameraIntrinsics[1, 1] * yScale
        let cx = cameraIntrinsics[2, 0] * xScale
        let cy = cameraIntrinsics[2, 1] * yScale

        let x = Int((cameraSpace4.x / depth * fx + cx).rounded())
        let y = Int((cameraSpace4.y / depth * fy + cy).rounded())
        guard x >= 0, y >= 0, x < Int(depthMapSize.width), y < Int(depthMapSize.height) else { return nil }
        return DepthPixel(x: x, y: y, vertexDistance: depth)
    }
}
