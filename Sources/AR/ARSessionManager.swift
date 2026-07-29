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
    private var didAttachFogPlane = false
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

    // Live occlusion veto tunables — see docs/superpowers/specs/2026-07-29-live-occlusion-veto-design.md.
    private let occlusionCenterConeHalfAngleDegrees: Float = 25
    private let maxOcclusionChecksPerRefresh = 300
    private let occlusionMarginMeters: Float = 0.05
    // "At or near" full confidence — avoids a razor-edge float equality check.
    private let occlusionConfidenceThreshold: Float = 0.999

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
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
            Self.logger.notice("smoothedSceneDepth enabled")
        } else {
            Self.logger.notice("smoothedSceneDepth not supported on this device — occlusion veto disabled")
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

// MARK: - Fog reveal rendering (SceneKit render thread)

extension ARSessionManager {
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // pointOfView doesn't exist until the session is actually running, so
        // the fog plane can't be attached at init.
        guard !didAttachFogPlane, let pointOfView = sceneView.pointOfView else { return }
        pointOfView.addChildNode(FogRevealRenderer.makeFogPlaneNode())
        didAttachFogPlane = true
        Self.logger.notice("fog plane attached to camera")
    }

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
        var confidences = [Float]()
        var worldPositions = [SIMD3<Float>]()
        confidences.reserveCapacity(vertices.count)
        worldPositions.reserveCapacity(vertices.count)
        withVoxelGridLock {
            for index in 0..<vertices.count {
                let local = vertices[index]
                let world4 = transform * SIMD4<Float>(local, 1)
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                worldPositions.append(world)
                confidences.append(voxelGrid.confidence(at: world))
            }
        }

        applyOcclusionVeto(confidences: &confidences, worldPositions: worldPositions)

        let geometry = FogRevealRenderer.makeGeometry(from: meshGeometry, confidences: confidences)
        node.geometry = geometry
        node.renderingOrder = FogRevealRenderer.meshRenderingOrder
    }

    /// Render-only veto: overrides `confidences` in place (never touches
    /// `VoxelGrid`) for vertices that are already confirmed but currently have
    /// something closer between them and the camera. See the design doc for
    /// why this can't reintroduce the earlier "confirmed area randomly
    /// re-fogs" bug — nothing stored is ever modified here.
    private func applyOcclusionVeto(confidences: inout [Float], worldPositions: [SIMD3<Float>]) {
        guard let frame = sceneView.session.currentFrame, let depthData = frame.smoothedSceneDepth else { return }

        let depthMap = depthData.depthMap
        guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let viewportSize = CGSize(width: width, height: height)

        let cameraTransform = frame.camera.transform
        let cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
        // ARKit's camera looks down its own local -Z axis.
        let cameraForward = -SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)

        var checksUsed = 0
        for index in 0..<confidences.count {
            guard checksUsed < maxOcclusionChecksPerRefresh else { break }
            guard confidences[index] >= occlusionConfidenceThreshold else { continue }

            let vertexWorldPosition = worldPositions[index]
            let vertexDirection = vertexWorldPosition - cameraPosition
            guard OcclusionVeto.isWithinCenterCone(
                vertexDirection: vertexDirection,
                cameraForward: cameraForward,
                halfAngleDegrees: occlusionCenterConeHalfAngleDegrees
            ) else { continue }

            checksUsed += 1

            let projected = frame.camera.projectPoint(vertexWorldPosition, orientation: .portrait, viewportSize: viewportSize)
            let x = Int(projected.x)
            let y = Int(projected.y)
            guard x >= 0, x < width, y >= 0, y < height else { continue }

            let rowPointer = baseAddress.advanced(by: y * bytesPerRow)
            let liveDepth = rowPointer.assumingMemoryBound(to: Float32.self)[x]
            let vertexDistance = simd_length(vertexDirection)

            if OcclusionVeto.isBlocked(liveDepth: liveDepth, vertexDistance: vertexDistance, marginMeters: occlusionMarginMeters) {
                confidences[index] = 0
            }
        }
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
