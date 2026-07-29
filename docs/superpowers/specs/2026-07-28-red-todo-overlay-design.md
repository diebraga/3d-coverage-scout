# Red To-Do Overlay Design

## Goal

Replace the current full mesh recoloring path with a smooth, red-only "to-do" overlay: surfaces that still need capture show red, and surfaces that have enough coverage show the normal camera feed with no color.

## User Experience

- The app never shows green.
- Newly detected or under-captured surfaces show a red overlay.
- Once a surface has enough valid coverage, its overlay disappears completely.
- If the user comes back to a finished area later, it stays clear.
- The red overlay should feel like a Scaniverse-style surface mask, but smooth camera and recording are more important than perfect triangle-by-triangle painting.
- The recorded video remains clean: no overlay is baked into the saved `.mov`.

## Root Cause Of Current Freeze

The current overlay rebuilds SceneKit geometry for AR mesh anchors. Each rebuild allocates a per-vertex color buffer, copies face data, creates a new `SCNGeometry`, and assigns it to the node. That work starts when colors appear, and it competes with ARKit camera tracking, LiDAR mesh updates, SceneKit rendering, and video recording. Throttling helped but did not remove the expensive architecture.

## Architecture

Keep `VoxelGrid` as the source of truth for coverage state. Stop using per-frame/per-anchor mesh recoloring as the primary visualization. Add a lightweight overlay renderer that creates capped red markers or coarse surface patches for only incomplete voxels.

The overlay renderer owns its own `SCNNode` children under a single root node. It refreshes on a fixed budget, diffs visible incomplete voxels against currently rendered nodes, and removes nodes for voxels that become good. It never creates nodes for green voxels.

## Performance Budgets

- Overlay refresh rate: at most 4 times per second.
- Maximum visible red overlay nodes: 800.
- Maximum new overlay nodes per refresh: 150.
- Maximum removed overlay nodes per refresh: 300.
- Observation sampling stays capped and independent from rendering.
- If the number of incomplete voxels exceeds the visible budget, prefer nearer voxels first.
- Overlay work must never hold the `VoxelGrid` lock while creating SceneKit geometry.

## Data Flow

1. `ARSessionManager.session(_:didUpdate:)` samples LiDAR mesh vertices and records observations into `VoxelGrid`.
2. `VoxelGrid` classifies each voxel as `.gray`, `.red`, or `.green`.
3. The overlay renderer asks `VoxelGrid` for a snapshot of incomplete voxels near the camera.
4. The renderer displays red overlay nodes only for snapshot entries that are not `.green`.
5. When a voxel becomes `.green`, the next refresh removes that red node.

## New Interfaces

`VoxelGrid` adds:

```swift
struct VoxelOverlaySample: Hashable {
    let coordinate: VoxelCoordinate
    let center: SIMD3<Float>
    let coverage: VoxelCoverage
}
```

```swift
func incompleteSamples(limit: Int, near cameraPosition: SIMD3<Float>) -> [VoxelOverlaySample]
```

`ARSessionManager` adds a private red overlay root node and updates it from throttled snapshots. This is internal implementation detail; no public app screen API changes.

## Rendering Shape

Use small red translucent SceneKit planes or boxes centered at incomplete voxel centers. The first implementation should use boxes because they are cheap, stable, and do not need per-surface tangent math. Upgrade to oriented planes only if boxes are smooth but visually too chunky.

## Testing

Automated tests cover `VoxelGrid.incompleteSamples`:

- empty grid returns no samples
- red/incomplete voxels are returned
- green voxels are excluded
- returned samples are sorted by distance to camera
- limit is enforced

Device validation covers smoothness and UX:

- camera remains smooth when red overlay appears
- completed areas disappear
- returning to completed areas does not show red
- recording still saves a clean video

## Out Of Scope

- Perfect Scaniverse triangle-accurate painting in this pass.
- Metal custom renderer.
- Exporting coverage data.
- Any reconstruction pipeline changes.

