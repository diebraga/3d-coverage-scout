# Why Coverage Scout Exists

Coverage Scout was built to solve a capture problem that shows up before any
3D reconstruction algorithm gets a chance to work.

The reconstruction pipeline can only infer accurate geometry, camera motion,
texture, and splats from the visual evidence captured in the input video. If a
room is recorded too quickly, from too few angles, too far from surfaces, or
with important areas missed entirely, the downstream reconstruction has to
guess. That usually appears later as holes, smeared geometry, warped surfaces,
poor texture alignment, unstable camera solves, or weak Gaussian splat
coverage.

Coverage Scout moves that quality check into the moment of capture. Instead of
recording a room blind and discovering the problems later on a workstation, the
app shows live guidance while the user is physically scanning. Its purpose is
not to reconstruct the room on the phone. Its purpose is to help capture better
source footage for reconstruction.

## The Core Problem

3D reconstruction depends on repeated, useful observations of the same real
surface from different viewpoints. One pass across a wall is usually not
enough. The reconstruction system needs parallax: the same area seen from
meaningfully different camera positions so structure-from-motion,
photogrammetry, NeRF-like processing, or Gaussian splatting can estimate depth
and appearance with confidence.

In normal phone video capture, the person scanning has no reliable way to know:

- which surfaces have already been captured well;
- which surfaces were only seen once;
- which areas were seen from a bad grazing angle;
- whether they moved too quickly;
- whether they were too close, too far, or too centered on the wrong area;
- whether an object or wall section is still missing good coverage;
- whether the footage will be good enough before they stop recording.

The result is a costly feedback loop: record a room, transfer the video, run
the reconstruction pipeline, inspect the output, notice missing or degraded
areas, then go back and rescan. Coverage Scout exists to shorten that loop.

## What The App Does

Coverage Scout is a native iOS scanning assistant for LiDAR-equipped iPhones.
It opens a live AR camera view, tracks the room with ARKit, uses the phone's
LiDAR sensor to understand approximate surface geometry, and overlays a
coverage visualization on top of the camera feed.

The overlay shows which parts of the scene still need better capture. As a
surface receives stronger observations from useful angles, the visual guidance
fades away and the normal camera image becomes clear again. The experience is
intended to feel like a Scaniverse-style capture overlay: the user can walk the
room and visually chase the remaining incomplete areas until the scene has
better coverage.

The saved output is still just a plain `.mov` video. The overlay is never
baked into the recording. That is important because the downstream
reconstruction pipeline needs clean camera frames, not UI graphics.

## Why It Improves Reconstruction Quality

Coverage Scout improves the input data, and better input data gives the
reconstruction pipeline a better chance of producing a stable result.

It helps in four practical ways:

1. It encourages multiple viewpoints.
   A surface is not considered complete just because it appeared once. The app
   looks for observations separated by enough viewing angle to provide useful
   parallax.

2. It discourages weak observations.
   Very close, very far, or highly grazing views are not treated as high-value
   coverage. Those shots often contribute less useful geometry and texture
   signal to reconstruction.

3. It exposes missed areas during capture.
   Instead of discovering holes after processing, the user sees incomplete
   areas while still standing in the room and can immediately rescan them.

4. It keeps the reconstruction input clean.
   The app records the raw AR camera frames to video. The guidance overlay is
   only a live preview, so the reconstruction pipeline receives normal footage.

For pipelines based on ffmpeg, COLMAP, Brush, Gaussian splatting, or similar
reconstruction workflows, this matters because the algorithms are highly
sensitive to camera coverage, overlap, parallax, motion blur, and missing
surface evidence. Coverage Scout is designed as the capture-quality layer
before that processing begins.

## What The App Does Not Do

Coverage Scout is not the reconstruction engine.

It does not:

- export a mesh;
- export Gaussian splats;
- run COLMAP on-device;
- process a final 3D model;
- replace the existing reconstruction pipeline;
- upload scans to a cloud service;
- act as a web viewer or iframe viewer.

The app's job is narrower and more useful at capture time: help the user record
a better video.

## How It Works

The app uses ARKit and LiDAR to maintain a live understanding of the room while
recording video.

At a high level:

1. ARKit tracks the phone's 6DOF pose as the user moves.
2. The LiDAR scanner produces a live scene mesh of nearby surfaces.
3. The app samples that mesh into a sparse world-space voxel grid.
4. Each voxel stores observations of nearby surface points.
5. The app classifies how well each voxel has been covered.
6. The live preview renders incomplete areas as guidance.
7. The video recorder writes clean camera frames to a `.mov` file.
8. The saved video goes into the existing reconstruction pipeline.

## Coverage Model

The app does not try to track individual ARKit mesh triangles. ARKit can refine
and rebuild mesh geometry over time, which makes triangle identity unstable.
Instead, Coverage Scout tracks coverage in a sparse voxel grid fixed in world
space.

The current grid uses 10 cm voxels. A voxel is created only when it intersects
observed LiDAR mesh surface, so the app does not allocate a dense cube for the
entire room. It stores only the parts of the room that have actually been seen.

For each surface observation, the app records:

- the surface position;
- the surface normal;
- the camera position;
- the viewing direction;
- the distance from camera to surface;
- the angle between the camera view and the surface normal.

An observation is useful only if it is within the expected scanning range and
angle:

- minimum valid distance: 0.3 m;
- maximum valid distance: 3.0 m;
- maximum angle to the surface normal: 60 degrees;
- minimum useful angular separation between views: 15 degrees.

Those numbers are simple, explicit heuristics. They encode the basic capture
truth: the pipeline needs surfaces to be seen clearly, nearby, and from more
than one useful angle.

## Confidence And Scan Quality

Coverage Scout keeps a confidence score for each voxel.

- A voxel with no useful observations has no confidence.
- A voxel seen from only one useful direction has partial confidence.
- A voxel seen from sufficiently different useful directions becomes
  confirmed.

The app also exposes a scan quality percentage:

```text
Scan quality = confirmed voxels / observed voxels
```

This is intentionally not called room completion. The app cannot know the full
extent of unscanned space in a room it has not seen yet. It can only measure
the quality of surfaces that have entered the scan.

## Live Visual Guidance

The preview is a guidance layer on top of the camera view. Earlier designs used
discrete red/green coverage states. The current direction is a more natural
fog/reveal model:

- unscanned or weakly scanned areas remain visually marked;
- partially covered areas become less obstructed;
- fully confirmed surfaces return to the plain camera image;
- already confirmed areas stay clear when revisited;
- temporary live occlusions can be vetoed with scene depth so a blocked
  confirmed surface does not incorrectly appear visible through an obstruction.

The implementation uses SceneKit/ARSCNView rendering over ARKit's camera feed.
The preview is deliberately lightweight: mesh samples are throttled, observation
counts are capped, confidence is cached, and expensive work is kept off the
main thread where possible.

## Recording Model

The camera is owned by the AR session. iOS does not allow the app to run an
independent normal camera capture session beside the AR session, so the app
records from `ARFrame.capturedImage`.

The video path is:

1. ARKit produces a captured camera frame.
2. The app passes the pixel buffer to `AVAssetWriter`.
3. Frames are paced to a stable recording rate.
4. The output is written as H.264 `.mov`.
5. The finished video is saved to the Photos library.

The overlay is not composited into the recording. The saved file is suitable
for the existing reconstruction workflow.

## Technologies Used

Coverage Scout is built with Apple's native AR and media stack:

- Swift and SwiftUI for the iOS app structure and UI.
- ARKit for camera tracking, world tracking, LiDAR scene reconstruction, and
  AR frames.
- LiDAR scene reconstruction for live room surface geometry.
- AR scene depth, where supported, for live depth checks and occlusion
  decisions.
- SceneKit / ARSCNView for the live scan preview overlay.
- simd math for geometry, normals, distances, and view-angle calculations.
- AVFoundation / AVAssetWriter for writing clean `.mov` video.
- Photos framework for saving the finished recording to the user's photo
  library.
- XCTest for pure coverage, voxel, pacing, and recording logic tests.
- XcodeGen for generating the Xcode project from `project.yml`.

## Requirements

### Hardware

Coverage Scout requires a physical LiDAR-equipped iPhone. In practice, that
means an iPhone Pro or Pro Max model with LiDAR, such as:

- iPhone 12 Pro / 12 Pro Max;
- iPhone 13 Pro / 13 Pro Max;
- iPhone 14 Pro / 14 Pro Max;
- iPhone 15 Pro / 15 Pro Max;
- iPhone 16 Pro / 16 Pro Max;
- newer compatible Pro models with LiDAR.

Non-LiDAR iPhones are out of scope because the app depends on ARKit scene
reconstruction.

### Software

The project targets:

- iOS 17.0 or later;
- Xcode with iOS device deployment support;
- Swift 5;
- XcodeGen for regenerating `CoverageScout.xcodeproj` from `project.yml`.

The app cannot be meaningfully tested in the iOS Simulator. ARKit scene
reconstruction, LiDAR, camera frames, and real tracking behavior require a
physical device.

### Permissions

The app needs:

- Camera permission, to run the AR session and capture video frames.
- Photos add permission, to save the completed `.mov` recording.

### Development Setup

The expected development loop is:

1. Install Xcode.
2. Install XcodeGen if the generated project is missing or stale.
3. Run `xcodegen generate` from the project root.
4. Open `CoverageScout.xcodeproj`.
5. Select a physical LiDAR iPhone as the run target.
6. Build and run on the device.
7. Grant camera and Photos permissions.
8. Validate scan behavior in a real room.

A free Apple developer account can install the app on a personal device, but
the install expires after 7 days and must be rebuilt. A paid Apple Developer
Program account removes that short personal-install expiry and is better for
longer-term device testing or distribution.

## Capture Workflow

The intended user workflow is:

1. Open Coverage Scout on a LiDAR iPhone.
2. Tap Start Recording.
3. Walk the room slowly while watching the coverage overlay.
4. Revisit marked or fogged areas until important surfaces are confirmed.
5. Stop recording.
6. Let the app save the clean `.mov` to Photos.
7. AirDrop or transfer the video to the Mac.
8. Drop the video into the reconstruction project's room input folder.
9. Run the normal reconstruction pipeline.

Coverage Scout deliberately preserves this simple handoff. It does not require
accounts, cloud sync, model hosting, or a new viewer to be useful.

## Why Native Instead Of A Browser Or Iframe

Coverage Scout is a capture tool, not a viewer. An iframe can embed a finished
viewer, but it cannot solve the live capture problem by itself.

The app needs direct access to:

- the camera feed;
- device motion and 6DOF tracking;
- ARKit world tracking;
- LiDAR scene reconstruction;
- depth maps;
- low-latency frame callbacks;
- local video writing.

On iOS, that capability lives in native ARKit. Safari does not provide the same
WebXR/LiDAR scene reconstruction path needed for this app. A browser viewer can
be useful after reconstruction, but the capture assistant belongs on-device as
a native app.

## Success Criteria

Coverage Scout is successful when it helps a user capture better footage in
one pass.

The practical signs are:

- fewer missed wall, floor, ceiling, and object surfaces;
- fewer areas seen from only one angle;
- fewer reconstruction holes;
- more stable camera solving downstream;
- cleaner geometry and splat placement;
- less need to return to the site for rescans;
- faster iteration between capture and final render.

The app improves reconstruction not by doing more processing, but by improving
what the processing receives.

