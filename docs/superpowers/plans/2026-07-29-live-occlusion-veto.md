# Live Occlusion Veto Implementation Plan

**Goal:** Implement the design in
`docs/superpowers/specs/2026-07-29-live-occlusion-veto-design.md` — a
confirmed surface re-fogs only while something currently blocks it, using
ARKit's live depth as a per-frame render-only veto.

**Architecture:** Three cheap filters (confidence gate, center-cone gate, hard
cap) narrow the candidate vertex set before any per-vertex live-depth lookup
runs, all inside the mesh rebuild's existing throttle. The pure geometry math
is isolated into a testable, ARKit-free file; the ARKit/CVPixelBuffer glue
around it is not (device-only, same as the rest of the AR pipeline).

**Tech Stack:** Swift 5, ARKit (`smoothedSceneDepth`, `ARCamera.projectPoint`),
SceneKit, simd, XCTest, XcodeGen.

## Global Constraints

- This feature never writes to `VoxelGrid`. It only affects the alpha buffer
  built for the current mesh rebuild.
- Gated behind `ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)`
  — unsupported devices simply skip this feature, no crash, no fallback path
  to maintain beyond "don't call it."
- Reuses the mesh rebuild's existing throttle; no new per-frame hot path.
- Center cone half-angle: 25°. `maxOcclusionChecksPerRefresh`: 300. Occlusion
  margin: 0.05m. (All three adjustable after device testing, not fixed by
  this plan.)
- `CoverageScout.xcodeproj` stays xcodegen-generated; never hand-edited.
- **Do not `git push` until the user confirms on device.**

---

### Task 1: Occlusion math (TDD)

**Files:**
- Create: `Sources/AR/OcclusionVeto.swift`
- Create: `Tests/OcclusionVetoTests.swift`

**Produces:**
- `enum OcclusionVeto`
- `static func isWithinCenterCone(vertexDirection: SIMD3<Float>, cameraForward: SIMD3<Float>, halfAngleDegrees: Float) -> Bool`
- `static func isBlocked(liveDepth: Float, vertexDistance: Float, marginMeters: Float) -> Bool`

Steps:
1. Write failing tests:
   - `isWithinCenterCone`: same direction → true; exactly at the boundary
     angle → true (inclusive); just past it → false; opposite direction → false.
   - `isBlocked`: live depth clearly closer than `vertexDistance - margin` →
     true; live depth equal to vertex distance → false; live depth closer but
     within the margin → false; live depth farther (behind the vertex) →
     false; live depth `0` → false; live depth `.nan` → false.
2. Run, confirm they fail to compile.
3. Implement both functions (pure `simd` math, no ARKit import):

```swift
import simd

enum OcclusionVeto {
    static func isWithinCenterCone(vertexDirection: SIMD3<Float>, cameraForward: SIMD3<Float>, halfAngleDegrees: Float) -> Bool {
        guard simd_length(vertexDirection) > 0 else { return false }
        let dot = simd_clamp(simd_dot(simd_normalize(vertexDirection), simd_normalize(cameraForward)), -1, 1)
        let angleDegrees = acos(dot) * 180 / .pi
        return angleDegrees <= halfAngleDegrees
    }

    static func isBlocked(liveDepth: Float, vertexDistance: Float, marginMeters: Float) -> Bool {
        guard liveDepth.isFinite, liveDepth > 0 else { return false }
        return liveDepth < vertexDistance - marginMeters
    }
}
```

4. Run full suite green.
5. Commit locally.

---

### Task 2: Wire the veto into the mesh rebuild

**Files:**
- Modify: `Sources/AR/ARSessionManager.swift`

**Consumes from Task 1:** `OcclusionVeto.isWithinCenterCone`, `OcclusionVeto.isBlocked`.

Steps:
1. Enable the depth frame semantic in `start()`, gated by support:

```swift
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
```

2. Add the tunables as private constants near the other throttle constants:

```swift
private let occlusionCenterConeHalfAngleDegrees: Float = 25
private let maxOcclusionChecksPerRefresh = 300
private let occlusionMarginMeters: Float = 0.05
// "At or near" full confidence — avoids a razor-edge float equality check.
private let occlusionConfidenceThreshold: Float = 0.999
```

3. In `updateFogGeometry`, change the confidence-resolution loop to also keep
   each vertex's world position (needed for the veto), then apply the veto
   before building geometry:

```swift
private func updateFogGeometry(node: SCNNode, meshAnchor: ARMeshAnchor) {
    let now = CACurrentMediaTime()
    guard shouldRebuildMesh(for: meshAnchor.identifier, now: now) else { return }

    let meshGeometry = meshAnchor.geometry
    let vertices = meshGeometry.vertices
    let transform = meshAnchor.transform

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
```

4. Add the veto itself as a new private method:

```swift
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
```

5. `xcodegen generate`, build for device SDK (`CODE_SIGNING_ALLOWED=NO`), run
   the full test suite.
6. Commit locally.

---

### Task 3: Device build, install, and user validation

**Files:** none (validation only).

Steps:
1. Build for the connected iPhone
   (`DEVELOPMENT_TEAM=VHWZ5GA82G`, `ENABLE_DEBUG_DYLIB=NO`, no
   `-allowProvisioningUpdates`).
2. Install and launch via `devicectl`.
3. Ask the user to validate against the spec's device checklist (cover a
   confirmed surface → it fogs; uncover → it reveals again immediately; no
   crash/freeze/frame-rate drop; saved video unaffected).
4. **Only after the user confirms it works: `git push`** — this covers both
   this feature and the still-unpushed drift-tolerance and gradual-reveal
   work from earlier in the session.
