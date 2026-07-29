import ARKit
import SceneKit
import Combine
import os

final class ARSessionManager: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    private static let logger = Logger(subsystem: "com.diebraga.CoverageScout", category: "ARSessionManager")

    let sceneView = ARSCNView()
    let voxelGrid = VoxelGrid()
    private let voxelGridLock = NSLock()
    private let frameCaptureLock = NSLock()
    private let coverageOverlayRenderer = FrostedCoverageOverlayRenderer()
    private var frameCaptureHandler: ((CVPixelBuffer, CMTime) -> Void)?

    // Touched only from ARSessionDelegate.didUpdate, which ARKit invokes serially.
    private var lastObservationTime: [UUID: TimeInterval] = [:]
    private let minObservationInterval: TimeInterval = 0.1
    private var lastOverlayRefresh: TimeInterval = 0
    private let minOverlayRefreshInterval: TimeInterval = 0.25

    @Published var qualityPercentage: Double = 0
    @Published var trackingMessage: String?
    @Published var isLiDARSupported: Bool = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    var onFrameCaptured: ((CVPixelBuffer, CMTime) -> Void)? {
        get {
            frameCaptureLock.lock()
            defer { frameCaptureLock.unlock() }
            return frameCaptureHandler
        }
        set {
            frameCaptureLock.lock()
            frameCaptureHandler = newValue
            frameCaptureLock.unlock()
        }
    }

    override init() {
        super.init()
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
        sceneView.scene.rootNode.addChildNode(coverageOverlayRenderer.rootNode)
    }

    func start() {
        Self.logger.notice("session start requested lidarSupported=\(self.isLiDARSupported)")
        guard isLiDARSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        Self.logger.notice("session stop")
        sceneView.session.pause()
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let timestamp = frame.timestamp.isNaN ? CMTime.zero : CMTime(seconds: frame.timestamp, preferredTimescale: 600)
        onFrameCaptured?(frame.capturedImage, timestamp)

        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )

        let now = Date().timeIntervalSince1970
        for anchor in frame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            let last = lastObservationTime[meshAnchor.identifier] ?? 0
            guard now - last >= minObservationInterval else { continue }
            lastObservationTime[meshAnchor.identifier] = now
            recordObservations(for: meshAnchor, cameraPosition: cameraPosition)
        }

        refreshRedOverlay(cameraPosition: cameraPosition, timestamp: frame.timestamp)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.qualityPercentage = self.withVoxelGridLock { self.voxelGrid.qualityPercentage }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let message: String?
        switch camera.trackingState {
        case .normal:
            message = nil
        case .limited(.excessiveMotion):
            message = "Move slower"
        case .limited(.insufficientFeatures):
            message = "Too little detail — try a different angle"
        case .limited(.initializing):
            message = "Getting ready…"
        case .limited(.relocalizing):
            message = "Relocalizing…"
        case .limited:
            message = "Tracking limited"
        case .notAvailable:
            message = "Tracking not available"
        @unknown default:
            message = nil
        }
        Self.logger.notice("trackingState=\(String(describing: camera.trackingState))")
        DispatchQueue.main.async { [weak self] in
            self?.trackingMessage = message
        }
    }

    // MARK: - Mesh -> voxel grid

    private func recordObservations(for meshAnchor: ARMeshAnchor, cameraPosition: SIMD3<Float>) {
        withVoxelGridLock {
            let geometry = meshAnchor.geometry
            let vertices = geometry.vertices
            let normals = geometry.normals
            let transform = meshAnchor.transform
            // Sample a subset of vertices per update to bound per-frame cost on a dense mesh.
            let stride = max(1, vertices.count / 500)

            for i in Swift.stride(from: 0, to: vertices.count, by: stride) {
                let localPosition = vertices[i]
                let localNormal = normals[i]
                let worldPosition4 = transform * SIMD4<Float>(localPosition, 1)
                let worldPosition = SIMD3<Float>(worldPosition4.x, worldPosition4.y, worldPosition4.z)
                let worldNormal = simd_normalize(
                    SIMD3<Float>(
                        transform.columns.0.x * localNormal.x + transform.columns.1.x * localNormal.y + transform.columns.2.x * localNormal.z,
                        transform.columns.0.y * localNormal.x + transform.columns.1.y * localNormal.y + transform.columns.2.y * localNormal.z,
                        transform.columns.0.z * localNormal.x + transform.columns.1.z * localNormal.y + transform.columns.2.z * localNormal.z
                    )
                )
                let observation = ObservationExtraction.observation(surfacePosition: worldPosition, surfaceNormal: worldNormal, cameraPosition: cameraPosition)
                voxelGrid.recordObservation(observation, at: worldPosition)
            }
        }
    }

    private func refreshRedOverlay(cameraPosition: SIMD3<Float>, timestamp: TimeInterval) {
        guard timestamp - lastOverlayRefresh >= minOverlayRefreshInterval else { return }
        lastOverlayRefresh = timestamp

        let samples = withVoxelGridLock {
            voxelGrid.incompleteSamples(limit: FrostedCoverageOverlayRenderer.maxVisibleNodes, near: cameraPosition)
        }
        Self.logger.debug("overlay refresh incompleteSamples=\(samples.count) at=\(timestamp, format: .fixed(precision: 3))")

        DispatchQueue.main.async { [weak self] in
            self?.coverageOverlayRenderer.update(samples: samples)
        }
    }

    private func withVoxelGridLock<T>(_ operation: () -> T) -> T {
        voxelGridLock.lock()
        defer { voxelGridLock.unlock() }
        return operation()
    }
}

private extension ARGeometrySource {
    // `count`, `buffer`, `format`, `offset`, `stride` are existing ARGeometrySource
    // properties from ARKit - only the subscript below is new.
    subscript(index: Int) -> SIMD3<Float> {
        precondition(format == .float3, "Expected float3 vertex/normal buffer")
        let pointer = buffer.contents().advanced(by: offset + stride * index)
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }
}
