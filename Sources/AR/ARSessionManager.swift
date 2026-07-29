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
    private let depthSnapshotLock = NSLock()
    // Confirmed by a real device crash log: ARSCNView defaults ARSessionDelegate
    // callbacks to the main thread unless given an explicit queue. Any per-frame
    // cost there (mesh sampling, voxel recording) risks blocking the UI long
    // enough for iOS's watchdog to SIGKILL the app. Moving it here is a
    // structural fix, not just a mitigation of the VoxelGrid growth bug.
    private let sessionDelegateQueue = DispatchQueue(label: "com.diebraga.CoverageScout.arsession", qos: .userInteractive)
    private var frameCaptureHandler: ((CVPixelBuffer, CMTime) -> Void)?

    // Touched only from ARSessionDelegate.didUpdate, which ARKit invokes serially
    // on sessionDelegateQueue (a serial queue) — still one-at-a-time, just off main.
    private var lastObservationTime: [UUID: TimeInterval] = [:]
    private let minObservationInterval: TimeInterval = 0.1

    // Touched only from the SCNSceneRendererDelegate callbacks, which SceneKit
    // invokes serially on its own render thread — never main, never the session
    // queue, so these need no lock of their own.
    private var lastMeshRebuild: [UUID: TimeInterval] = [:]
    private let minMeshRebuildInterval: TimeInterval = 0.3
    // Second, global bound on top of the per-anchor throttle: with enough
    // anchors in a large room the per-anchor limit alone still allows a lot of
    // rebuilds per second. Rebuilds are off the main thread, but keeping the
    // total bounded is what stops this path ever becoming the next stall.
    private var meshRebuildsInWindow = 0
    private var meshRebuildWindowStart: TimeInterval = 0
    private let maxMeshRebuildsPerSecond = 8
    private let occlusionMarginMeters: Float = 0.06
    private var latestDepthSnapshot: DepthSnapshot?

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
        sceneView.session.delegateQueue = sessionDelegateQueue
        sceneView.automaticallyUpdatesLighting = true
    }

    func start() {
        Self.logger.notice("session start requested lidarSupported=\(self.isLiDARSupported)")
        guard isLiDARSupported else { return }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
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
        updateDepthSnapshot(from: frame)

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

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.qualityPercentage = self.withVoxelGridLock { self.voxelGrid.qualityPercentage }
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        // Evidence for a suspected coordinate-drift issue: if a tracking dip is
        // ever followed by previously-scanned surfaces re-fogging, this position
        // (compared against the position logged at the next transition) shows
        // whether ARKit actually reported a jump.
        let position = camera.transform.columns.3
        Self.logger.notice("trackingState=\(String(describing: camera.trackingState)) cameraPosition=(\(position.x, format: .fixed(precision: 3)), \(position.y, format: .fixed(precision: 3)), \(position.z, format: .fixed(precision: 3)))")

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

// MARK: - Scan preview rendering (SceneKit render thread)

extension ARSessionManager {
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        updateFogGeometry(node: node, meshAnchor: meshAnchor)
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        updateFogGeometry(node: node, meshAnchor: meshAnchor)
    }

    func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
        guard let meshAnchor = anchor as? ARMeshAnchor else { return }
        lastMeshRebuild.removeValue(forKey: meshAnchor.identifier)
    }

    private func updateFogGeometry(node: SCNNode, meshAnchor: ARMeshAnchor) {
        let now = CACurrentMediaTime()
        guard shouldRebuildMesh(for: meshAnchor.identifier, now: now) else { return }

        let meshGeometry = meshAnchor.geometry
        let vertices = meshGeometry.vertices
        let transform = meshAnchor.transform

        // Resolve every vertex's confidence under the lock (cheap dictionary
        // reads of a cached float), then release it before building the buffers.
        let depthSnapshot = withDepthSnapshotLock { latestDepthSnapshot }
        var worldPositions = [SIMD3<Float>]()
        var confidences = [Float]()
        worldPositions.reserveCapacity(vertices.count)
        confidences.reserveCapacity(vertices.count)
        withVoxelGridLock {
            for index in 0..<vertices.count {
                let local = vertices[index]
                let world4 = transform * SIMD4<Float>(local, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                worldPositions.append(world)
                confidences.append(voxelGrid.confidence(at: world))
            }
        }
        let visible = visibilityMask(for: worldPositions, snapshot: depthSnapshot)

        let geometry = FogRevealRenderer.makeGeometry(from: meshGeometry, confidences: confidences, visible: visible)
        node.geometry = geometry
        node.renderingOrder = FogRevealRenderer.meshRenderingOrder
    }

    private func shouldRebuildMesh(for anchorID: UUID, now: TimeInterval) -> Bool {
        if now - meshRebuildWindowStart >= 1 {
            meshRebuildWindowStart = now
            meshRebuildsInWindow = 0
        }
        guard meshRebuildsInWindow < maxMeshRebuildsPerSecond else { return false }

        let last = lastMeshRebuild[anchorID] ?? 0
        guard now - last >= minMeshRebuildInterval else { return false }

        lastMeshRebuild[anchorID] = now
        meshRebuildsInWindow += 1
        return true
    }

    private func updateDepthSnapshot(from frame: ARFrame) {
        guard let depthMap = frame.sceneDepth?.depthMap else { return }
        withDepthSnapshotLock {
            latestDepthSnapshot = DepthSnapshot(
                depthMap: depthMap,
                cameraTransform: frame.camera.transform,
                cameraIntrinsics: frame.camera.intrinsics,
                cameraImageResolution: frame.camera.imageResolution
            )
        }
    }

    private func visibilityMask(for worldPositions: [SIMD3<Float>], snapshot: DepthSnapshot?) -> [Bool] {
        var visible = Array(repeating: true, count: worldPositions.count)
        guard let snapshot else { return visible }
        let width = CVPixelBufferGetWidth(snapshot.depthMap)
        let height = CVPixelBufferGetHeight(snapshot.depthMap)

        CVPixelBufferLockBaseAddress(snapshot.depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(snapshot.depthMap, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(snapshot.depthMap) else { return visible }
        let floatsPerRow = CVPixelBufferGetBytesPerRow(snapshot.depthMap) / MemoryLayout<Float32>.stride
        let depths = baseAddress.assumingMemoryBound(to: Float32.self)
        let stride = FogRevealRenderer.samplingStride(vertexCount: worldPositions.count)
        for index in Swift.stride(from: 0, to: worldPositions.count, by: stride) {
            guard let pixel = OcclusionVeto.depthPixel(
                for: worldPositions[index],
                cameraTransform: snapshot.cameraTransform,
                cameraIntrinsics: snapshot.cameraIntrinsics,
                cameraImageResolution: snapshot.cameraImageResolution,
                depthMapSize: CGSize(width: width, height: height)
            ) else { continue }
            let liveDepth = depths[pixel.y * floatsPerRow + pixel.x]
            visible[index] = !OcclusionVeto.isBlocked(
                liveDepth: liveDepth,
                vertexDistance: pixel.vertexDistance,
                marginMeters: occlusionMarginMeters
            )
        }
        return visible
    }

    private func withDepthSnapshotLock<T>(_ operation: () -> T) -> T {
        depthSnapshotLock.lock()
        defer { depthSnapshotLock.unlock() }
        return operation()
    }
}

private struct DepthSnapshot {
    let depthMap: CVPixelBuffer
    let cameraTransform: simd_float4x4
    let cameraIntrinsics: simd_float3x3
    let cameraImageResolution: CGSize
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
