import ARKit
import CoreMedia

struct ARFrameMetadataSnapshot: Equatable {
    let arkitTimestampSeconds: Double
    let cameraTransform: [[Float]]
    let intrinsics: [[Float]]
    let imageResolution: [Int]
    let trackingState: String
    let scanQuality: Double
    let sceneDepthEnabled: Bool

    init(
        arkitTimestampSeconds: Double,
        cameraTransform: simd_float4x4,
        intrinsics: simd_float3x3,
        imageResolution: CGSize,
        trackingState: ARCamera.TrackingState,
        scanQuality: Double,
        sceneDepthEnabled: Bool
    ) {
        self.arkitTimestampSeconds = arkitTimestampSeconds
        self.cameraTransform = Self.rows(from: cameraTransform)
        self.intrinsics = Self.rows(from: intrinsics)
        self.imageResolution = [Int(imageResolution.width), Int(imageResolution.height)]
        self.trackingState = Self.description(for: trackingState)
        self.scanQuality = scanQuality
        self.sceneDepthEnabled = sceneDepthEnabled
    }

    func frameMetadata(videoTimestamp: CMTime) -> ScanFrameMetadata {
        ScanFrameMetadata(
            videoTimestampSeconds: videoTimestamp.seconds,
            arkitTimestampSeconds: arkitTimestampSeconds,
            cameraTransform: cameraTransform,
            intrinsics: intrinsics,
            imageResolution: imageResolution,
            trackingState: trackingState,
            scanQuality: scanQuality
        )
    }

    static func rows(from matrix: simd_float4x4) -> [[Float]] {
        [
            [matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x, matrix.columns.3.x],
            [matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y, matrix.columns.3.y],
            [matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z, matrix.columns.3.z],
            [matrix.columns.0.w, matrix.columns.1.w, matrix.columns.2.w, matrix.columns.3.w]
        ]
    }

    static func rows(from matrix: simd_float3x3) -> [[Float]] {
        [
            [matrix.columns.0.x, matrix.columns.1.x, matrix.columns.2.x],
            [matrix.columns.0.y, matrix.columns.1.y, matrix.columns.2.y],
            [matrix.columns.0.z, matrix.columns.1.z, matrix.columns.2.z]
        ]
    }

    static func description(for trackingState: ARCamera.TrackingState) -> String {
        switch trackingState {
        case .normal:
            "normal"
        case .limited(.excessiveMotion):
            "limited_excessive_motion"
        case .limited(.insufficientFeatures):
            "limited_insufficient_features"
        case .limited(.initializing):
            "limited_initializing"
        case .limited(.relocalizing):
            "limited_relocalizing"
        case .limited:
            "limited"
        case .notAvailable:
            "not_available"
        @unknown default:
            "unknown"
        }
    }
}

