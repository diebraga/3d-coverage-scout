# Gradual Fog Reveal Design

## Goal

Replace the current discrete overlay (translucent boxes floating at incomplete
voxel centres) with the Scaniverse-style experience the user demonstrated in a
reference video: **the whole scene starts fogged, and the real camera image is
revealed gradually as each surface is captured with increasing confidence.**

## User Experience

- The scene starts **fully fogged** — a soft, neutral, translucent haze over
  everything. Nothing is legible until it has been scanned.
- As the user scans a surface, that surface's fog **thins gradually**, in
  proportion to how confidently it has been captured.
- A fully-captured surface shows the **plain, unmodified camera image**. No
  colour tint, no green, no markers, no outline — exactly the real image.
- Returning to an already-captured area shows it **still clear**. Coverage is
  never re-fogged during a session.
- The overlay is app UI guidance only. It is **never** baked into the saved
  video.

## Naming Correction

The existing classifier labels a well-covered voxel `.green`. That is an
internal enum case name only — it has never rendered as a green tint and will
not. This document uses **"confirmed"** for that state to avoid the confusion
that name caused during design.

## Why Not The Alternatives

Three approaches were considered and rejected before landing here:

1. **A 2D blur/frost shader over the camera image.** This is what Scaniverse
   most likely does, but it needs a custom Metal render pass over the camera
   texture — the largest amount of new, untested graphics surface of any option.
2. **A dense 3D point cloud from ARKit's depth map (`sceneDepth`).** Rejected
   on cost: it requires transforming thousands of depth pixels to world space
   every frame, and that per-frame cost never decreases no matter how complete
   the scan gets.
3. **Sampling points from the LiDAR mesh vertices.** Cheaper, but ARKit's mesh
   triangles are several centimetres across, so the resulting dot field is too
   sparse to read as fog.

The chosen approach inverts the problem: **fog is the cheap default state, and
the only work is subtracting from it.** A single full-screen plane costs
essentially nothing regardless of scene complexity, and the subtraction reuses
the mesh geometry and coverage data the app already computes.

## Architecture

Two cooperating pieces, both rendered by SceneKit in the existing `ARSCNView`:

### 1. Fog plane

A single large `SCNPlane` attached as a child of the AR camera node
(`sceneView.pointOfView`), sitting at a fixed distance just beyond the useful
scanning range (3.2 m — the classifier's `maxValidDistance` is 3.0 m). Because
it is parented to the camera, it always fills the view with no per-frame work.

Material: flat neutral fog colour, constant lighting, alpha blended, **reads**
the depth buffer but does **not write** to it, high `renderingOrder` so it
draws after the mesh.

### 2. Mesh reveal layer

For every `ARMeshAnchor`, SceneKit renders the real LiDAR mesh geometry with a
per-vertex alpha driven by that vertex's voxel confidence:

- `alpha = 1 - confidence` — so an unscanned surface is opaque fog colour, and
  a fully-confirmed surface is fully transparent.
- The material's colour is the **same** fog colour as the plane, so a
  low-confidence mesh region is visually indistinguishable from the plane
  behind it — no seam, no double-darkening.
- The mesh **writes to the depth buffer** and has a lower `renderingOrder` than
  the fog plane. The plane's fragments therefore fail the depth test wherever
  mesh exists and are discarded — so mesh regions are governed solely by their
  own alpha, and the plane only shows where LiDAR has not reached yet.

Net effect, entirely through standard depth testing with no custom shader:

| Situation | What the user sees |
|---|---|
| No mesh yet | Fog plane — fully fogged |
| Mesh, confidence 0 | Opaque fog-coloured mesh — indistinguishable from fog |
| Mesh, confidence 0.5 | Half-transparent — real image faintly legible |
| Mesh, confidence 1 | Fully transparent — plain real camera image |

## Confidence Score

`VoxelGrid` already stores, per voxel, a capped list of at most 8 valid
`Observation`s. The score is derived from that same data — no new tracking, no
new ARKit API:

```
confidence(observations):
    valid = observations.filter(isValid)
    if valid is empty: return 0
    maxSeparation = largest pairwise angular separation among valid, or 0 if only one
    return min(maxSeparation / minAngularSeparationDegrees, 1)
```

This is deliberately continuous where the existing classification is discrete,
and the two stay consistent by construction: `confidence == 1.0` exactly when
the classifier would return `.green`/confirmed (both use the same 15°
`minAngularSeparationDegrees` threshold).

The score is **computed once when an observation is recorded and cached**
alongside the existing classification. Rendering only ever reads the cached
float. This matters: recomputing it during rendering would reintroduce
per-frame O(n²) work, which is the shape of the bug that crashed the app.

## Crash Safety

The app was previously killed by iOS's watchdog (`0x8BADF00D`) during exactly
this kind of mesh work, so the constraints that fixed it are load-bearing here:

- **Both root causes are already fixed and independent of this feature:** the
  unbounded per-voxel observation array (now capped at 8) and the ARKit session
  delegate running on the main thread (now on a dedicated background queue).
  The rendering path was never the thing that froze — the crash log's faulting
  thread was `com.apple.main-thread` inside `recordObservation`, while SceneKit
  rendering was already on its own `com.apple.scenekit.scnview-renderer` thread.
- Confidence is cached, never computed during rendering (above).
- Mesh geometry rebuilds stay **throttled** per anchor, reusing the existing
  `minRebuildInterval` pattern.
- A **hard cap on vertices processed per refresh cycle** bounds the cost of a
  single rebuild even on the background thread, so a suddenly-large scanned
  region cannot produce one oversized rebuild.

## Data Flow

1. ARKit delivers frames and mesh anchors on the background session queue.
2. `ARSessionManager` samples mesh vertices and records observations into
   `VoxelGrid` (unchanged from today).
3. `VoxelGrid` updates that voxel's classification **and** its cached
   confidence score.
4. SceneKit's renderer delegate rebuilds an anchor's geometry (throttled),
   reading cached confidence per vertex to build the alpha channel.
5. Depth testing composites mesh over fog plane over camera feed.

## Recording

Unchanged. The saved `.mov` is written from `ARFrame.capturedImage` directly
and never sees the SceneKit overlay. The recently-added portrait rotation
transform stays as-is.

## Testing

Automated (`XCTest`, runnable on Simulator):

- `confidence` returns 0 for no observations and for only-invalid observations.
- `confidence` returns 0 for a single valid observation (no separation yet).
- `confidence` increases as angular separation increases.
- `confidence` is exactly 1.0 at and beyond the confirmed threshold.
- `confidence` never exceeds 1.0 regardless of how wide the separation is.
- `VoxelGrid` exposes the cached score, and it stays 1.0 once confirmed.
- Existing classification/quality-percentage behaviour is unchanged.

Device validation (manual, required — none of the rendering is verifiable off
a physical LiDAR device):

- Scene starts fully fogged.
- Fog thins progressively while scanning a surface, not in one jump.
- A finished surface shows the plain camera image with no tint or marker.
- Looking away and returning leaves a finished surface clear.
- No crash, freeze, or watchdog kill during an extended session including
  revisits.
- The saved video contains no fog, no overlay, and is upright.

## Known Risk

The gradual reveal depends on SceneKit honouring per-vertex alpha *and*
depth-buffer writes on the same partially-transparent material. This is
standard, but it is graphics behaviour that cannot be verified anywhere except
on the device. If it does not composite correctly, the fallback is the binary
version of the same architecture: render confirmed mesh regions depth-only
(`colorBufferWriteMask = []`) to punch an exact hole in the fog plane, losing
only the gradual fade while keeping every other property of this design.

## Out Of Scope

- Metal/custom shaders.
- 2D image-space blur.
- Depth-map point clouds.
- Directional "move here next" guidance.
- Camera pose export (planned separately as a Version 1 item).
- Any change to recording, saving, or the reconstruction pipeline.
