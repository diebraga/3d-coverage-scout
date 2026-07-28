import ARKit
import SceneKit
import Combine

final class ARSessionManager: NSObject, ObservableObject, ARSCNViewDelegate, ARSessionDelegate {
    let sceneView = ARSCNView()
    let voxelGrid = VoxelGrid()
    private let voxelGridLock = NSLock()
    private let frameCaptureLock = NSLock()
    private var frameCaptureHandler: ((CVPixelBuffer, CMTime) -> Void)?

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
        let timestamp = frame.timestamp.isNaN ? CMTime.zero : CMTime(seconds: frame.timestamp, preferredTimescale: 600)
        onFrameCaptured?(frame.capturedImage, timestamp)

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

extension ARSessionManager {
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        updateGeometry(node: node, meshAnchor: meshAnchor)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        updateGeometry(node: node, meshAnchor: meshAnchor)
    }

    private func updateGeometry(node: SCNNode, meshAnchor: ARMeshAnchor) {
        let geometry = meshAnchor.geometry
        let vertexSource = geometry.vertices
        let transform = meshAnchor.transform

        var colors: [SCNVector4] = []
        colors.reserveCapacity(vertexSource.count)
        withVoxelGridLock {
            for i in 0..<vertexSource.count {
                let local = vertexSource[i]
                let world4 = transform * SIMD4<Float>(local, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                colors.append(color(for: voxelGrid.classification(at: world)))
            }
        }

        let colorData = Data(bytes: colors, count: colors.count * MemoryLayout<SCNVector4>.stride)
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SCNVector4>.stride
        )

        let scnGeometry = SCNGeometry(from: geometry, replacingColorWith: colorSource)
        node.geometry = scnGeometry
        let material = scnGeometry.firstMaterial ?? SCNMaterial()
        material.lightingModel = .constant
        material.isDoubleSided = true
        material.transparency = 1.0
        material.blendMode = .alpha
        scnGeometry.firstMaterial = material
    }
}

private extension SCNGeometry {
    convenience init(from meshGeometry: ARMeshGeometry, replacingColorWith colorSource: SCNGeometrySource) {
        let vertexSource = SCNGeometrySource(
            buffer: meshGeometry.vertices.buffer,
            vertexFormat: meshGeometry.vertices.format,
            semantic: .vertex,
            vertexCount: meshGeometry.vertices.count,
            dataOffset: meshGeometry.vertices.offset,
            dataStride: meshGeometry.vertices.stride
        )

        let faces = meshGeometry.faces
        let faceData = Data(bytes: faces.buffer.contents(), count: faces.buffer.length)
        let element = SCNGeometryElement(
            data: faceData,
            primitiveType: .triangles,
            primitiveCount: faces.count,
            bytesPerIndex: faces.bytesPerIndex
        )

        self.init(sources: [vertexSource, colorSource], elements: [element])
    }
}
