import Foundation

final class ScanMetadataRecorder {
    private let lock = NSLock()
    private var videoFilename = "scan.mov"
    private var width = 0
    private var height = 0
    private var frameRate = 30
    private var createdAt = Date()
    private var frames: [ScanFrameMetadata] = []
    private var sawSceneDepth = false

    var durationSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return frames.last?.videoTimestampSeconds ?? 0
    }

    var startedAt: Date {
        lock.lock()
        defer { lock.unlock() }
        return createdAt
    }

    func start(videoFilename: String, width: Int, height: Int, frameRate: Int, createdAt: Date) {
        lock.lock()
        self.videoFilename = videoFilename
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.createdAt = createdAt
        frames = []
        sawSceneDepth = false
        lock.unlock()
    }

    func append(frame: ScanFrameMetadata, sceneDepthEnabled: Bool = false) {
        lock.lock()
        frames.append(frame)
        sawSceneDepth = sawSceneDepth || sceneDepthEnabled
        lock.unlock()
    }

    func finish(durationSeconds: Double, scanQualityFinal: Double, sceneDepthEnabled: Bool? = nil) -> ScanMetadataDocument {
        lock.lock()
        let document = ScanMetadataDocument(
            schemaVersion: 1,
            app: "Coverage Scout",
            createdAt: Self.iso8601String(from: createdAt),
            arkitWorldUnits: "meters",
            video: ScanVideoMetadata(
                filename: videoFilename,
                width: width,
                height: height,
                frameRate: frameRate,
                durationSeconds: durationSeconds
            ),
            capture: ScanCaptureMetadata(
                deviceSupportsLidar: true,
                sceneReconstruction: "mesh",
                sceneDepthEnabled: sceneDepthEnabled ?? sawSceneDepth,
                voxelSizeMeters: VoxelGrid.voxelSize,
                scanQualityFinal: scanQualityFinal
            ),
            frames: frames
        )
        lock.unlock()
        return document
    }

    func encodedDocument(durationSeconds: Double, scanQualityFinal: Double, sceneDepthEnabled: Bool? = nil) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(finish(
            durationSeconds: durationSeconds,
            scanQualityFinal: scanQualityFinal,
            sceneDepthEnabled: sceneDepthEnabled
        ))
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
