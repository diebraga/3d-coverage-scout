import ARKit
import SceneKit
import Combine

final class ARSessionManager: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    let sceneView = ARSCNView()
    let voxelGrid = VoxelGrid()

    @Published var qualityPercentage: Double = 0
    @Published var trackingMessage: String?
    @Published var isLiDARSupported: Bool = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)

    var onFrameCaptured: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        super.init()
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.automaticallyUpdatesLighting = true
    }

    func start() {
        guard isLiDARSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        sceneView.session.pause()
    }

    func color(for coverage: VoxelCoverage) -> SCNVector4 {
        switch coverage {
        case .gray: return SCNVector4(0.6, 0.6, 0.6, 0.35)
        case .red: return SCNVector4(1.0, 0.2, 0.2, 0.55)
        case .green: return SCNVector4(0.2, 1.0, 0.2, 0.55)
        }
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        onFrameCaptured?(frame.capturedImage, frame.timestamp.isNaN ? CMTime.zero : CMTime(seconds: frame.timestamp, preferredTimescale: 600))

        let cameraPosition = SIMD3<Float>(
            frame.camera.transform.columns.3.x,
            frame.camera.transform.columns.3.y,
            frame.camera.transform.columns.3.z
        )

        for anchor in frame.anchors {
            guard let meshAnchor = anchor as? ARMeshAnchor else { continue }
            recordObservations(for: meshAnchor, cameraPosition: cameraPosition)
        }

        DispatchQueue.main.async { [weak self] in
            self?.qualityPercentage = self?.voxelGrid.qualityPercentage ?? 0
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
        DispatchQueue.main.async { [weak self] in
            self?.trackingMessage = message
        }
    }

    // MARK: - Mesh -> voxel grid

    private func recordObservations(for meshAnchor: ARMeshAnchor, cameraPosition: SIMD3<Float>) {
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

private extension ARGeometrySource {
    // `count`, `buffer`, `format`, `offset`, `stride` are existing ARGeometrySource
    // properties from ARKit - only the subscript below is new.
    subscript(index: Int) -> SIMD3<Float> {
        precondition(format == .float3, "Expected float3 vertex/normal buffer")
        let pointer = buffer.contents().advanced(by: offset + stride * index)
        return pointer.assumingMemoryBound(to: SIMD3<Float>.self).pointee
    }
}
