# Gradual Fog Reveal Implementation Plan

**Goal:** Implement the design in
`docs/superpowers/specs/2026-07-29-gradual-fog-reveal-design.md` — fog
everywhere by default, revealed gradually per-surface as scan confidence rises.

**Architecture:** A camera-parented fog plane provides the default fogged
state. The LiDAR mesh renders over it with per-vertex alpha driven by a cached
confidence score, writing depth so it occludes the plane. No custom shaders.

**Tech Stack:** Swift 5, SwiftUI, ARKit, SceneKit, XCTest, XcodeGen.

## Global Constraints

- Confidence is computed on record and cached; never recomputed while rendering.
- Mesh geometry rebuilds stay throttled per anchor.
- A hard cap bounds vertices processed per rebuild.
- Rendering stays off the main thread.
- The saved `.mov` never contains the overlay.
- Fog colour is identical between plane and mesh (no seam).
- `CoverageScout.xcodeproj` stays xcodegen-generated; never hand-edited.
- **Do not `git push` until the user confirms the feature works on device.**

---

### Task 1: Confidence score (TDD)

**Files:**
- Modify: `Sources/Coverage/CoverageClassifier.swift`
- Modify: `Sources/Coverage/VoxelGrid.swift`
- Modify: `Tests/CoverageClassifierTests.swift`
- Modify: `Tests/VoxelGridTests.swift`

**Produces:**
- `CoverageClassifier.confidence(_ observations: [Observation]) -> Float`
- `VoxelGrid.confidence(at worldPosition: SIMD3<Float>) -> Float`

Steps:
1. Write failing tests for `confidence` (empty → 0, only-invalid → 0, single
   valid → 0, partial separation → between 0 and 1, at/over threshold → 1).
2. Write failing test that `VoxelGrid` caches and exposes the score, and that
   it stays 1.0 after a voxel is confirmed.
3. Run tests, confirm they fail to compile/assert.
4. Implement `confidence` in `CoverageClassifier` by reusing the existing
   `isValid` filter and `angularSeparationDegrees` helper.
5. Cache it in `VoxelGrid.recordObservation` next to the classification, and
   expose `confidence(at:)` returning 0 for unknown voxels.
6. Run full suite green.
7. Commit locally.

---

### Task 2: Fog plane and mesh reveal renderer

**Files:**
- Create: `Sources/AR/FogRevealRenderer.swift`
- Modify: `Sources/AR/ARSessionManager.swift`
- Delete: `Sources/AR/FrostedCoverageOverlayRenderer.swift`

**Produces:**
- `FogRevealRenderer` owning the fog colour, the fog plane node, and mesh
  geometry construction with per-vertex alpha.

Steps:
1. Create `FogRevealRenderer` with:
   - `static let fogColor`, shared between plane and mesh.
   - `makeFogPlaneNode()` — large `SCNPlane` at −3.2 m, constant lighting,
     alpha blend, reads depth, does not write depth, high `renderingOrder`.
   - `makeMeshNodeGeometry(from:confidenceLookup:)` — builds an `SCNGeometry`
     from an `ARMeshGeometry` with a per-vertex colour source whose RGB is the
     fog colour and whose alpha is `1 - confidence`, capped at a maximum
     vertex count per rebuild, writing depth, lower `renderingOrder`.
2. In `ARSessionManager`:
   - Replace the `FrostedCoverageOverlayRenderer` property and its
     `incompleteSamples`-driven refresh with `FogRevealRenderer`.
   - Attach the fog plane to `sceneView.pointOfView` once it exists.
   - Implement `renderer(_:didAdd:for:)` / `renderer(_:didUpdate:for:)` for
     `ARMeshAnchor`s, throttled per anchor, assigning the rebuilt geometry.
   - Read confidence under the existing `voxelGridLock`, but build geometry
     outside the lock.
3. Delete the obsolete renderer file.
4. `xcodegen generate`, build for device SDK, run full test suite.
5. Commit locally.

---

### Task 3: Device build, install, and user validation

**Files:** none (validation only).

Steps:
1. Build for the connected iPhone
   (`DEVELOPMENT_TEAM=VHWZ5GA82G`, `ENABLE_DEBUG_DYLIB=NO`, no
   `-allowProvisioningUpdates`).
2. Install and launch via `devicectl`.
3. Ask the user to validate against the spec's device checklist.
4. **Only after the user confirms it works: `git push`.**
