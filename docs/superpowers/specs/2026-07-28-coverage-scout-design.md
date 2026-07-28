# Coverage Scout — LiDAR Scan Coverage App

## Purpose

A native iOS app (target: iPhone with LiDAR, e.g. 12 Pro+) that gives real-time
visual feedback — like Scaniverse's coverage overlay — while walking through a
room, so the user knows which surfaces still need better coverage *before*
they stop recording. The app's only output is a plain video file, which then
feeds unchanged into the existing `3d-reconstructions` pipeline
(ffmpeg → COLMAP → Brush) as a normal `raw/` video.

The app does not do 3D reconstruction, splat export, or any processing beyond
live coverage feedback + recording. It is a capture-quality aid, not a
reconstruction tool.

## Why not browser-based

Investigated and ruled out: Safari on iOS has no WebXR support, so no 6DOF
camera tracking is available in-browser. The only browser option (8th Wall) is
paid and still requires building the coverage logic from scratch on top of it.
ARKit already provides free, on-device 6DOF tracking + LiDAR mesh — a native
app is strictly less work than reimplementing tracking in a browser.

## Architecture

- SwiftUI app, two screens: an idle start screen and the live AR/recording
  screen (see "Screen flow" below).
- `ARSession` with `ARWorldTrackingConfiguration`, `sceneReconstruction = .mesh`
  (LiDAR scene mesh) and `.smoothedSceneDepth` if available for more stable
  per-point ranges.
- RealityKit (`ARView`) for drawing the live camera passthrough + colorized
  mesh overlay — the standard, lowest-boilerplate pairing with ARKit/SwiftUI.
- Recording reuses the same `ARSession`'s frames rather than opening a second
  camera session (the camera is exclusively locked to one session at a time,
  so a separate `AVCaptureSession` can't run alongside `ARSession` anyway):
  each `ARFrame.capturedImage` pixel buffer is written straight to an
  `AVAssetWriter` `.mov`, undecorated — no overlay is ever composited into
  the recorded frames, only into the on-screen `ARView`.

Requires a physical LiDAR-equipped iPhone to run or test — ARKit does not run
in the iOS Simulator or on macOS (no Catalyst support either). Development
loop: build from Xcode straight to device over cable, then wirelessly once
paired (Xcode → Devices → "Connect via network").

## Coverage tracking (the core logic)

ARKit's mesh geometry is refined/re-triangulated over time, so per-triangle
IDs are not stable to track observations against. Instead, coverage is
tracked on a **sparse world-space voxel grid** (10cm voxels, hash-mapped by
integer voxel coordinate — only voxels that intersect actual LiDAR mesh
surface are ever created, so this stays cheap for a room-sized space, e.g. a
5m×5m×3m room is ~75k voxels max).

This is the same idea as classic volumetric/TSDF fusion (what Open3D's
offline pipelines do) — the difference is ARKit supplies pose and depth for
free in real time, so no odometry has to be implemented here.

For each voxel, record every **valid observation**: a camera frame where the
voxel's surface point is between **0.3m–3m** from the camera, and the angle
between the surface normal and the camera-to-point ray is **≤60° from
perpendicular** (excludes grazing shots that give poor texture/geometry
signal).

Classification per voxel:
- **Gray** — no mesh/no observations yet.
- **Red** — has ≥1 valid observation, but all valid observations are within
  15° of each other (i.e. only ever seen from ~one viewpoint — insufficient
  parallax for good triangulation).
- **Green** — has ≥2 valid observations whose viewing directions differ by
  **≥15°** — a direct proxy for the parallax SfM/Brush need.

Running totals (green voxel count, red voxel count) are updated incrementally
whenever a voxel's classification changes — never a full-grid rescan — so the
quality percentage can update every frame cheaply.

**Quality % = green voxels ÷ (green + red voxels)**, i.e. *of what's been
scanned, how much is good* — not room completion (unscanned area is excluded
from the denominator since its true extent is unknown). Labeled explicitly as
"Scan quality: NN%", never "Complete: NN%", to avoid implying full-room
coverage.

## Rendering

The live camera feed is shown with the ARKit mesh overlaid as translucent
colored triangles (looked up per-vertex against its containing voxel's
current color). A small HUD shows the live quality percentage.

## Screen flow

1. **Idle start screen** — no camera preview yet. Just a red circular button
   with a "+" in the middle, labeled "Start Recording". The AR session isn't
   created until this is tapped (keeps the idle screen trivial and avoids
   burning battery/camera access before the user is ready).
2. Tapping it creates the `ARSession`, presents the live camera + colorized
   coverage overlay + quality-% HUD (see Rendering above), and immediately
   starts recording — one tap, no separate confirm step. The same button
   (now a stop icon) is the only way to end the session.
3. Tapping again stops both the AR session and the recording, writes the
   `.mov` to the Photos library, tears down the AR session, and returns
   straight to the idle start screen (screen 1) with a brief "Saved" toast/
   checkmark — ready to immediately start another take.

No custom transfer mechanism beyond saving to Photos — the user AirDrops the
saved video to their Mac and drops it into `<house>/<room>/raw/` exactly as
they already do today per the existing pipeline's step 0. Nothing about the
existing pipeline changes.

## Error handling

ARKit already reports tracking-quality issues (excessive motion, low light,
insufficient visual texture) via `ARCamera.TrackingState`. The app surfaces
that existing reason as a small banner (e.g. "Move slower", "Too dark") —
no custom motion/lighting detection is built.

If launched on a device without LiDAR (`supportsSceneReconstruction(.mesh)`
false), the app shows a blocking error message. No non-LiDAR fallback mode is
built.

## Testing

The only nontrivial logic in this app is the voxel classification (valid
observation check + gray/red/green rule + angular-separation check). That
logic is written as a pure Swift function taking synthetic observation data
(distances, angles) and returning a classification, with no ARKit dependency
— it runs as a normal XCTest on the Mac, no device needed. Example cases:
two valid observations 20° apart → green; one grazing observation → red (or
gray, since a grazing shot may not count as valid at all); no observations →
gray.

The AR session, rendering, and recording plumbing can only be verified by
running on the physical device (see Architecture) — no test coverage is
attempted for that layer, it's exercised manually.

## Out of scope

- Non-LiDAR devices.
- Browser/WebXR delivery (ruled out — see above).
- Any 3D reconstruction, splat export, or mesh export from this app — its
  only output is the plain video file.
- Multi-room or whole-house scanning in one session (matches the existing
  pipeline's one-room-per-reconstruction model).
- Video trimming/editing in-app.
- Cloud sync, accounts, or login.
- Testing on macOS/Simulator (not possible — ARKit hardware dependency).
