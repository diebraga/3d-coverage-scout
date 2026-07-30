# Coverage Scout

Coverage Scout is a native iOS app for LiDAR-equipped iPhones that helps record
better source footage for 3D reconstruction. It gives live scan-coverage
feedback while a room is being captured, so the user can see which surfaces
still need better viewpoints before they stop recording.

The app does not reconstruct the model on the phone. Its output is a clean
`.mov` video that can be fed into a separate reconstruction pipeline such as
ffmpeg -> COLMAP -> Brush, Gaussian splatting, or another photogrammetry / 3D
reconstruction workflow.

## Why This App Exists

3D reconstruction quality depends heavily on capture quality. If the input
video misses important surfaces, sees surfaces from only one angle, moves too
quickly, or captures walls and objects from grazing viewpoints, the
reconstruction pipeline has to guess. That often produces holes, warped
geometry, unstable camera solves, smeared textures, or weak Gaussian splat
coverage.

Coverage Scout moves that quality check into the capture moment. Instead of
recording a room, processing it later, and only then discovering that a wall,
corner, ceiling area, floor section, or object was poorly captured, the app
shows the problem live while the user is still in the room.

The goal is simple: reduce rescans and improve the raw footage that downstream
3D reconstruction depends on.

## What It Does

- Starts a live AR room-scanning session on a LiDAR iPhone.
- Uses ARKit world tracking to know where the camera is in 3D space.
- Uses LiDAR scene reconstruction to understand nearby room surfaces.
- Tracks whether surfaces have been seen from enough useful viewpoints.
- Shows incomplete or weakly captured areas in the live preview.
- Lets well-covered surfaces fade back to the normal camera image.
- Records a clean `.mov` video without baking the overlay into the footage.
- Saves the video to Photos so it can be transferred into the reconstruction
  pipeline.

## What It Does Not Do

Coverage Scout is a capture-quality assistant, not a reconstruction engine.

It does not:

- export a mesh;
- export Gaussian splats;
- run COLMAP on-device;
- process a final 3D model;
- host a web viewer;
- replace the existing reconstruction pipeline.

## How It Improves 3D Reconstruction

Most reconstruction systems need the same real surface to appear in multiple
frames from meaningfully different viewpoints. This difference in viewpoint is
parallax, and it is critical for estimating camera motion, depth, geometry, and
surface appearance.

Coverage Scout encourages better reconstruction input by checking for:

- **coverage:** whether a surface has been observed at all;
- **view diversity:** whether it has been seen from more than one useful angle;
- **distance quality:** whether the camera is within the useful scanning range;
- **viewing angle:** whether the surface is being seen too obliquely;
- **missed regions:** whether parts of the room still need attention.

This means the person scanning can make better decisions while recording:
slow down, revisit an area, change angle, move closer, back up, or circle an
object before ending the take.

## Technical Approach

Coverage Scout uses Apple's native AR stack:

1. `ARWorldTrackingConfiguration` starts a 6DOF AR session.
2. ARKit tracks the camera pose as the user moves through the room.
3. LiDAR scene reconstruction provides a live mesh of nearby surfaces.
4. The app samples mesh vertices into a sparse world-space voxel grid.
5. Each voxel stores observations of nearby surface points.
6. Coverage confidence is computed from valid observations and viewing-angle
   separation.
7. SceneKit renders a lightweight live overlay on top of the AR camera feed.
8. `AVAssetWriter` records clean camera frames from `ARFrame.capturedImage`.
9. The resulting `.mov` is saved to the Photos library.

The overlay exists only on screen. The saved video remains clean because the
reconstruction pipeline needs camera footage, not UI graphics.

## Coverage Model

ARKit's mesh can be refined and rebuilt over time, so the app does not rely on
stable triangle IDs. Instead, it tracks coverage in a sparse voxel grid fixed in
world space.

The current model uses 10 cm voxels. A voxel is created only when observed
LiDAR mesh surface enters that space, keeping the grid practical for room-scale
capture.

For each observation, the app records:

- surface position;
- surface normal;
- camera position;
- viewing direction;
- camera-to-surface distance;
- angle between the camera view and the surface normal.

The current thresholds are:

- minimum valid distance: `0.3 m`;
- maximum valid distance: `3.0 m`;
- maximum angle to surface normal: `60 degrees`;
- minimum useful angular separation between views: `15 degrees`.

A voxel becomes confirmed when it has enough valid view separation to indicate
that the surface was captured with useful parallax.

## Scan Quality

The app reports scan quality as:

```text
confirmed voxels / observed voxels
```

This is a quality score, not a room-completion score. The app cannot know the
true extent of a room before it has seen it, so unobserved space is not treated
as part of the denominator.

## Technologies Used

- Swift
- SwiftUI
- ARKit
- LiDAR scene reconstruction
- AR scene depth
- SceneKit / `ARSCNView`
- simd geometry math
- AVFoundation / `AVAssetWriter`
- Photos framework
- XCTest
- XcodeGen

## Requirements

### Hardware

Coverage Scout requires a physical LiDAR-equipped iPhone, such as an iPhone Pro
or Pro Max model with LiDAR.

Non-LiDAR devices are not supported because the app depends on ARKit scene
reconstruction.

### Software

- iOS 17.0 or later
- Xcode with iOS device deployment support
- Swift 5
- XcodeGen, if regenerating the Xcode project from `project.yml`

### Permissions

- Camera permission, for AR tracking and video capture.
- Photos add permission, for saving completed recordings.

## Development Setup

1. Install Xcode.
2. Install XcodeGen if needed.
3. Run `xcodegen generate` from the project root if the Xcode project is
   missing or stale.
4. Open `CoverageScout.xcodeproj`.
5. Select a physical LiDAR iPhone as the run target.
6. Build and run on device.
7. Grant camera and Photos permissions.
8. Validate scanning behavior in a real room.

The app cannot be meaningfully tested in the iOS Simulator because ARKit scene
reconstruction, camera frames, LiDAR, and real tracking require physical
hardware.

## Capture Workflow

1. Open Coverage Scout on a LiDAR iPhone.
2. Start recording.
3. Walk the room slowly while watching the live coverage feedback.
4. Revisit weakly covered areas until the important surfaces are confirmed.
5. Stop recording.
6. Let the app save the clean `.mov` to Photos.
7. Transfer the video to the reconstruction machine.
8. Drop the video into the reconstruction pipeline's room input folder.
9. Run the normal reconstruction process.

## More Detail

The longer rationale and implementation notes are in
[`docs/why-coverage-scout.md`](docs/why-coverage-scout.md).

