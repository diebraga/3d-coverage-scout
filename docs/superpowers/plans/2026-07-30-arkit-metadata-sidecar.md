# ARKit Metadata Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Export each completed Coverage Scout recording as a paired Files-app folder containing the clean `.mov` video and an ARKit `scan_metadata.json` sidecar for downstream reconstruction context.

**Architecture:** Add a pure Swift metadata model/recorder that captures one ARKit camera snapshot for every accepted recorded video frame. Keep `VideoRecorder` responsible for `.mov` writing, add a separate `ScanFileExporter` for app Documents export, and keep Photos saving as an optional convenience path after the paired Files export succeeds.

**Tech Stack:** Swift, SwiftUI, ARKit, AVFoundation, Foundation `Codable`, app Documents directory, XCTest, README Markdown.

## Global Constraints

- The saved `.mov` must remain clean camera footage with no overlay composited into it.
- Metadata samples must correspond only to frames accepted by `RecordingFramePacer`, not every ARKit callback.
- The canonical paired export is a timestamped folder in the app Documents directory so it appears in iOS Files.
- Keep saving the video to Photos as a convenience, but do not save JSON to Photos.
- Do not try to feed ARKit poses into COLMAP in this app change; the sidecar is for the downstream pipeline to consume later.
- iOS Simulator cannot validate ARKit capture behavior; pure encoding/export tests run as XCTest.

---

## JSON Contract

Write `scan_metadata.json` beside `scan.mov`:

```json
{
  "schema_version": 1,
  "app": "Coverage Scout",
  "created_at": "2026-07-30T19:12:45Z",
  "arkit_world_units": "meters",
  "video": {
    "filename": "scan.mov",
    "width": 1920,
    "height": 1080,
    "frame_rate": 30,
    "duration_seconds": 42.5
  },
  "capture": {
    "device_supports_lidar": true,
    "scene_reconstruction": "mesh",
    "scene_depth_enabled": true,
    "voxel_size_meters": 0.1,
    "scan_quality_final": 78.4
  },
  "frames": [
    {
      "video_timestamp_seconds": 0.0,
      "arkit_timestamp_seconds": 12345.678,
      "camera_transform": [
        [1.0, 0.0, 0.0, 0.12],
        [0.0, 1.0, 0.0, 1.43],
        [0.0, 0.0, 1.0, -0.55],
        [0.0, 0.0, 0.0, 1.0]
      ],
      "intrinsics": [
        [1420.0, 0.0, 960.0],
        [0.0, 1420.0, 540.0],
        [0.0, 0.0, 1.0]
      ],
      "image_resolution": [1920, 1080],
      "tracking_state": "normal",
      "scan_quality": 42.1
    }
  ]
}
```

### Task 1: Metadata Model And Recorder

**Files:**
- Create: `Sources/Metadata/ScanMetadata.swift`
- Create: `Sources/Metadata/ScanMetadataRecorder.swift`
- Test: `Tests/ScanMetadataRecorderTests.swift`

**Interfaces:**
- Produces: `struct ScanFrameMetadata: Codable, Equatable`, `struct ScanMetadataDocument: Codable, Equatable`, `final class ScanMetadataRecorder`
- Produces: `ScanMetadataRecorder.start(videoFilename:width:height:frameRate:createdAt:)`, `append(frame:)`, `finish(durationSeconds:scanQualityFinal:sceneDepthEnabled:) -> ScanMetadataDocument`, `encodedDocument(...) throws -> Data`

- [x] Write failing tests for JSON key names, matrix shapes, append order, and final video/capture fields.
- [x] Run `xcodebuild test -scheme CoverageScout -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:CoverageScoutTests/ScanMetadataRecorderTests` and confirm the new types are missing.
- [x] Implement the Codable models with snake_case JSON keys via explicit `CodingKeys`.
- [x] Implement `ScanMetadataRecorder` as a pure Swift accumulator with no ARKit dependency.
- [x] Re-run the focused test and confirm it passes.

### Task 2: ARKit Snapshot Extraction

**Files:**
- Create: `Sources/Metadata/ARFrameMetadataSnapshot.swift`
- Modify: `Sources/AR/ARSessionManager.swift`
- Test: `Tests/ARFrameMetadataSnapshotTests.swift`

**Interfaces:**
- Produces: `struct ARFrameMetadataSnapshot: Equatable`
- Produces: `typealias ARFrameCaptureHandler = (CVPixelBuffer, CMTime, ARFrameMetadataSnapshot) -> Void`
- Consumes: `ARFrame.camera.transform`, `ARFrame.camera.intrinsics`, `ARFrame.camera.imageResolution`, `ARCamera.TrackingState`

- [x] Write failing pure tests for matrix serialization helpers and tracking-state string conversion.
- [x] Change `ARSessionManager.onFrameCaptured` to include `ARFrameMetadataSnapshot` captured from the same `ARFrame` as the pixel buffer.
- [x] Include ARKit timestamp, 4x4 transform, 3x3 intrinsics, image resolution, tracking state, current scan quality, and LiDAR/depth flags.
- [x] Keep frame capture locking behavior unchanged.
- [x] Run focused metadata snapshot tests.

### Task 3: Files-App Export Bundle

**Files:**
- Create: `Sources/Recording/ScanFileExporter.swift`
- Modify: `Sources/Info.plist`
- Modify: `project.yml`
- Test: `Tests/ScanFileExporterTests.swift`

**Interfaces:**
- Produces: `struct ScanExportResult { let folderURL: URL; let videoURL: URL; let metadataURL: URL }`
- Produces: `enum ScanFileExporter { static func export(videoURL:metadataData:createdAt:fileManager:documentsDirectory:) throws -> ScanExportResult }`

- [x] Write failing tests using a temporary directory: export creates one timestamped folder, copies video as `scan.mov`, writes `scan_metadata.json`, and preserves source video.
- [x] Implement exporter with deterministic folder names from `createdAt`, collision suffixes if needed, and atomic JSON write.
- [x] Add `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` to `Sources/Info.plist` and `project.yml` so the app Documents directory is visible in Files.
- [x] Run focused exporter tests.

### Task 4: Recording Flow Integration

**Files:**
- Modify: `Sources/ContentView.swift`

**Interfaces:**
- Consumes: `ARFrameMetadataSnapshot`, `ScanMetadataRecorder`, `ScanFileExporter`, `VideoRecorder`, `PhotoSaver`

- [x] Start a fresh `ScanMetadataRecorder` when recording begins, using the first recorded frame's width/height and `scan.mov` as the metadata video filename.
- [x] For each accepted pacer timestamp, append a metadata frame whose `video_timestamp_seconds` matches the timestamp passed to `VideoRecorder.appendFrame`.
- [x] On stop, finish video writing, encode metadata, export both files to Documents, then save the video to Photos as a convenience.
- [x] Update success/failure toast text to reflect the paired Files export, e.g. `Scan saved to Files` and `Scan could not be saved`.
- [x] Leave AR session start/stop behavior and clean video recording behavior unchanged.

### Task 5: README Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/why-coverage-scout.md`

**Interfaces:**
- Consumes: JSON contract above.

- [x] Add a README section explaining the paired Files export folder.
- [x] Include the JSON structure and explain the immediate downstream uses: diagnostics, frame selection, and later COLMAP context.
- [x] Update the detailed docs with the same sidecar concept and explicitly state that COLMAP integration is future pipeline work.

### Task 6: Final Verification

**Files:**
- All files above.

- [x] Run all available unit tests with `xcodebuild test -scheme CoverageScout -destination 'platform=iOS Simulator,name=iPhone 16'` if a simulator is available.
- [x] If simulator/device test execution is unavailable locally, run `xcodebuild -list` and any compile-only command available, then state the limitation clearly.
- [x] Run the documentation placeholder scan across README, docs, Sources, and Tests, avoiding false positives from this checklist item.
- [x] Review `git diff --stat` and `git status --short` before commit.
- [x] Commit with `feat: export ARKit metadata sidecar` and push to `origin main`.

