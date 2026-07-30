import Foundation

struct ScanMetadataDocument: Codable, Equatable {
    let schemaVersion: Int
    let app: String
    let createdAt: String
    let arkitWorldUnits: String
    let video: ScanVideoMetadata
    let capture: ScanCaptureMetadata
    let frames: [ScanFrameMetadata]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case app
        case createdAt = "created_at"
        case arkitWorldUnits = "arkit_world_units"
        case video
        case capture
        case frames
    }
}

struct ScanVideoMetadata: Codable, Equatable {
    let filename: String
    let width: Int
    let height: Int
    let frameRate: Int
    let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case filename
        case width
        case height
        case frameRate = "frame_rate"
        case durationSeconds = "duration_seconds"
    }
}

struct ScanCaptureMetadata: Codable, Equatable {
    let deviceSupportsLidar: Bool
    let sceneReconstruction: String
    let sceneDepthEnabled: Bool
    let voxelSizeMeters: Float
    let scanQualityFinal: Double

    enum CodingKeys: String, CodingKey {
        case deviceSupportsLidar = "device_supports_lidar"
        case sceneReconstruction = "scene_reconstruction"
        case sceneDepthEnabled = "scene_depth_enabled"
        case voxelSizeMeters = "voxel_size_meters"
        case scanQualityFinal = "scan_quality_final"
    }
}

struct ScanFrameMetadata: Codable, Equatable {
    let videoTimestampSeconds: Double
    let arkitTimestampSeconds: Double
    let cameraTransform: [[Float]]
    let intrinsics: [[Float]]
    let imageResolution: [Int]
    let trackingState: String
    let scanQuality: Double

    enum CodingKeys: String, CodingKey {
        case videoTimestampSeconds = "video_timestamp_seconds"
        case arkitTimestampSeconds = "arkit_timestamp_seconds"
        case cameraTransform = "camera_transform"
        case intrinsics
        case imageResolution = "image_resolution"
        case trackingState = "tracking_state"
        case scanQuality = "scan_quality"
    }
}

