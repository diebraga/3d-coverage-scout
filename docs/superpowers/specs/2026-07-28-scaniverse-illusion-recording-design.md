# Scaniverse Illusion And Stable Recording Design

## Goal

Build a Scaniverse-like live capture illusion for Coverage Scout while keeping the exported video clean and smooth. The app should guide the user with an on-screen frosted/blurred coverage surface, show elapsed recording time, stop recording promptly, and save only the raw camera feed for the separate Gaussian splat pipeline.

## User Experience

- The first screen stays a simple scan start screen.
- During scanning, weak or unscanned surfaces appear as a soft frosted translucent overlay on top of the live camera.
- Properly captured surfaces become visually clear by removing the overlay, revealing the normal camera feed.
- The app never shows green coverage.
- The previous red dot/box overlay is replaced by the frosted surface illusion.
- The overlay is only app UI guidance. It must never be baked into the saved `.mov`.
- While recording, the app shows an elapsed timer in `MM:SS` format.
- Pressing stop should immediately change the UI out of recording state, then finish writing and saving in the background.
- The saved video should play smoothly through camera movement, with no visual overlay, blur, UI, or coverage markers.

## Non-Goals

- No live Gaussian splat rendering.
- No live textured reconstruction preview.
- No projecting camera frames onto the mesh.
- No on-device reconstruction or "Process Now" flow.
- No export of coverage metadata in this pass.

## Current Problems

The current red overlay is now light enough for live camera preview, but recording still has two problems:

1. The latest frame gate protects the camera by allowing only one encoder task in flight. That avoids an unlimited backlog, but it can produce irregular saved video when frames are skipped under load.
2. Stopping recording currently waits for `AVAssetWriter.finishWriting` and the app transitions back to idle only after the writer callback starts resolving. This makes stop feel delayed.

The root recording issue is not the frosted overlay itself; it is mixing ARKit's real-time frame stream with video writing without a stable output cadence.

## Architecture

Keep `ARSessionManager` as the owner of ARKit/SceneKit. Keep `VoxelGrid` as the source of truth for coverage. Replace `RedTodoOverlayRenderer` with a renderer that displays capped frosted surface patches for incomplete voxels only.

The frosted renderer should stay cheap:

- Snapshot incomplete voxels from `VoxelGrid`.
- Render a capped number of translucent, low-detail SceneKit nodes near the camera.
- Use a shared material so all nodes do not allocate separate materials.
- Refresh at a capped rate.
- Remove nodes when voxels become covered.
- Do not create geometry while holding the voxel grid lock.

Recording should be handled through a small frame pacer:

- Accept frames at a fixed target cadence, initially 30 fps.
- Use monotonic output timestamps starting at zero for the saved movie.
- Drop extra AR frames deliberately between cadence ticks.
- Never enqueue unlimited frames.
- Keep live preview responsive by doing encoding work off the AR session delegate path.

The timer should be UI-only state derived from recording start time. It should not depend on encoder progress.

## Data Flow

1. ARKit produces camera frames and mesh anchors.
2. `ARSessionManager` records mesh observations into `VoxelGrid`.
3. `VoxelGrid` classifies voxels as incomplete or good.
4. The frosted overlay renderer snapshots incomplete voxels near the camera and renders only those.
5. When a voxel becomes good, the next overlay refresh removes its frosted visual.
6. If recording is active, captured camera pixel buffers are offered to the frame pacer.
7. The frame pacer accepts only frames that match the target output cadence and gives them stable output timestamps.
8. `VideoRecorder` writes accepted raw camera frames to `.mov`.
9. Stop immediately updates UI, ends frame acceptance, finishes the writer, and saves the file to Photos in the background.

## Performance Budgets

- Overlay refresh: at most 4 times per second.
- Visible frosted nodes: start at 600 maximum.
- New overlay nodes per refresh: start at 120 maximum.
- Removed overlay nodes per refresh: start at 240 maximum.
- Recording output cadence: 30 fps maximum.
- No overlay work should run on every camera frame.
- No writer call should run synchronously on the AR session callback beyond a small gate check.

## Visual Treatment

Use small translucent white/gray SceneKit boxes or planes at incomplete voxel centers as the first implementation. Give them a frosted illusion through alpha, constant lighting, and soft neutral color. Do not use expensive real blur or live texture projection in this pass.

The target feel is:

- unscanned = soft cloudy/frosted surface
- scanned = normal camera
- moving camera = smooth app preview

If boxes look too dotted, a later pass can switch to oriented planes or coarse merged patches. That is explicitly not part of the first implementation.

## Recording Behavior

Recording starts from the first accepted frame. The saved movie's first timestamp should be zero. Each accepted frame gets the next fixed-frame timestamp: `0`, `1/30`, `2/30`, and so on. This makes the output file smooth even when ARKit provides frames irregularly or extra frames are dropped.

If the encoder cannot accept a frame at a cadence tick, skip that frame and keep the next timestamp stable. Prefer a shorter/smoother video over blocking the live camera.

Stop should:

- immediately set `isRecording = false`
- stop accepting new frames
- clear the frame capture callback
- finish writing asynchronously
- save to Photos asynchronously
- return to idle without waiting for Photos save

## Testing

Automated tests:

- Frame pacer accepts the first frame.
- Frame pacer rejects frames before the next cadence tick.
- Frame pacer accepts the next cadence frame with the expected output timestamp.
- Frame pacer resets when a new recording generation starts.
- `VideoRecorder` still produces a non-empty movie from paced timestamps.
- Overlay snapshot behavior remains covered by `VoxelGrid` tests.

Device validation:

- app preview remains smooth with the frosted overlay visible
- covered areas clear away
- returning to covered areas stays clear
- timer counts while recording
- tapping stop updates UI immediately
- saved video has no overlay
- saved video plays smoothly through movement

## Out Of Scope

- Perfect Scaniverse visual parity.
- Actual blur shaders.
- Metal renderer.
- Mesh texture baking.
- Reconstruction preview after scan completion.
- In-app splat training.
