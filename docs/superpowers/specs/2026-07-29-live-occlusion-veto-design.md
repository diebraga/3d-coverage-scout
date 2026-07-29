# Live Occlusion Veto Design

## Goal

Fix the fog reveal's remaining artifact: an already-confirmed surface can show
through a gap in front of it when something currently blocking it (an object,
a person's hand, anything) hasn't been meshed by LiDAR yet from the current
angle. Confirmed by the user watching the fog-reveal feature in use.

## User Experience

- A confirmed (fully revealed) surface, when something now stands between it
  and the camera, **fogs again for as long as that obstruction is there.**
- The instant the obstruction is gone, the surface **shows as revealed again
  automatically** — no re-scanning needed, because nothing about its stored
  confidence ever changed.
- This must not reintroduce the "confirmed area randomly re-fogs" bug already
  fixed (the voxel drift-tolerance fix) — this feature only ever affects what
  is drawn for the current frame, never `VoxelGrid`'s stored data.

## Why This Wasn't Caught By The Existing Design

The fog reveal (see `2026-07-29-gradual-fog-reveal-design.md`) decides what to
draw purely from the *persistent* LiDAR mesh plus cached per-voxel confidence.
That mesh does not update instantly when something new blocks a previously
scanned surface — LiDAR mesh reconstruction has inherent latency, and a
surface that was meshed once generally stays in the mesh even while currently
occluded. The renderer has no live signal that says "something is in front of
this confirmed surface right now" — it only knows what has been meshed.

## Prerequisite

`smoothedSceneDepth` is not on by default — unlike the mesh, which the app
already requests. `ARWorldTrackingConfiguration.frameSemantics` must add
`.smoothedSceneDepth`, gated behind
`ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)`
the same way LiDAR mesh support is already gated. If unsupported on a given
device, this feature is simply unavailable there and the existing fog-only
behavior (no live occlusion check) is the fallback — never a crash.

## Architecture

An additional, narrowly-scoped check layered on top of the existing mesh
rebuild in `ARSessionManager`/`FogRevealRenderer`. Three filters stack to keep
it cheap, applied in this order (cheapest/most-eliminating first):

1. **Confidence gate.** Only vertices at or near full confidence (already
   revealed) are candidates. A still-fogged vertex cannot exhibit this
   artifact — it already renders correctly regardless of what's in front of
   it — so it is skipped before any of the more expensive checks below.
2. **Center-of-view gate.** Of the remaining candidates, only those within a
   configurable cone angle of the camera's current forward direction are
   checked further — a single dot-product against the camera's forward
   vector, no screen-space projection needed for this step. The user's own
   framing intuition: what's centered is what's being actively scanned and
   is worth the live check; the periphery is not.
3. **Hard cap.** At most `maxOcclusionChecksPerRefresh` candidates (after the
   two filters above) actually get the expensive live-depth check, regardless
   of how many survived filtering. Chosen arbitrarily low first and raised
   only if it visibly isn't enough once tested on-device.

For each vertex that survives all three filters:

- Project it into the camera's image plane (`ARCamera.projectPoint`).
- Sample ARKit's `smoothedSceneDepth` at that projected pixel (nearest sample
  in the depth map's own, lower resolution — no interpolation needed for a
  first version).
- If the live depth reading is meaningfully **closer** than the vertex's own
  distance from the camera (beyond a small margin, to absorb sensor noise —
  not a hair-trigger on every minor fluctuation), something is currently
  between the camera and that surface. Render that vertex fogged (alpha = 1)
  for this frame, overriding its cached confidence.
- Otherwise render it exactly as the existing gradual-reveal logic already
  does.

This is a **per-frame render decision only.** `VoxelGrid`'s stored
classification and confidence are never written to by this feature. The next
refresh re-evaluates from scratch; there is no state to "restore."

## Data Flow

1. `ARSessionManager`'s existing throttled mesh rebuild (`updateFogGeometry`)
   runs as today, building the per-vertex alpha from cached `VoxelGrid`
   confidence.
2. Before finalizing that frame's alpha buffer, apply the three-filter
   candidate selection above to the vertices that came out at (or near) full
   confidence.
3. For selected candidates, look up `frame.smoothedSceneDepth`, compare, and
   override alpha to fogged where something closer is present.
4. Everything else in the existing pipeline (fog plane, depth-buffer
   occlusion between plane and mesh, recording) is unchanged.

## Performance

This reuses the mesh rebuild's existing throttle (per-anchor interval +
global rebuilds-per-second cap) — it does not add a new per-frame hot path.
Within that existing throttled pass, the added cost is bounded three ways
(gate 1, gate 2, hard cap in gate 3) before any per-vertex depth lookup runs,
so the worst case is `maxOcclusionChecksPerRefresh` projections + depth
samples per rebuild, not "every revealed vertex in the scene."

Initial values (adjustable once tested live, not fixed by this document):

- Center cone half-angle: 25°.
- `maxOcclusionChecksPerRefresh`: 300.
- Occlusion margin (how much closer live depth must read to count as
  "blocking"): 5cm — small enough to catch a real obstruction, large enough
  to not flicker on LiDAR sensor noise alone.

## Testing

Automated (`XCTest`, runnable on Simulator): the pure geometry math —
given a camera forward vector and a candidate vertex direction, does the
center-cone filter correctly include/exclude at and around the boundary
angle; given a live depth reading and a vertex distance, does the "closer
than by more than the margin" comparison correctly decide blocked/not-blocked
at and around the margin boundary.

Device validation (manual, required — ARKit's depth API and real occlusion
cannot be verified off a physical LiDAR device):

- Cover a previously-confirmed surface with a hand or object: it fogs.
- Remove the obstruction: the surface reveals again immediately, without
  re-scanning.
- No change in behavior for surfaces near the edge of the frame (outside the
  center cone) — they keep behaving exactly as before this feature.
- No crash, freeze, or noticeable frame-rate drop introduced.
- Saved video is unaffected (this feature only touches the AR overlay).

## Out Of Scope

- Any change to how confidence is computed, stored, or drifts-tolerated —
  that logic is untouched.
- Smoothing/hysteresis on the occlusion decision beyond the fixed margin
  (e.g. a decay so a very brief flicker doesn't instantly re-fog) — worth
  considering later if the margin alone feels twitchy in practice, not part
  of this pass.
- Extending the live-depth check to vertices outside the center cone.
