# Task 8 Report: Wire the screens together

## Implementation

- `ContentView` now switches between `IdleStartView` and `ARCoverageScreen`.
- Starting a scan guards for LiDAR support, starts the AR session, and records captured frames.
- Stopping pauses AR, detaches the capture callback, finalizes and saves the video, removes the temporary file, and returns to idle.
- A short confirmation appears after Photos saves the video.

## Verification

- `git diff --check` passed before commit.
- `git show --check HEAD` passed after commit.
- `xcodebuild` was not run because this Mac lacks the full Xcode/iOS SDK, as noted in the task brief.

## Review Fixes

- Serialized all `VideoRecorder` access on a dedicated queue and added a lock-protected callback gate so callbacks already in flight are drained before finalization and callbacks arriving after detachment are ignored.
- Moved temporary `.mov` deletion into the successful Photos-save branch; recorder or Photos failures now preserve the file and show a minimal failure state.
- `swiftc -parse Sources/ContentView.swift` passed. Full Xcode build remains unavailable on this Mac.

## Commit

- `cf849cb Wire idle and AR screens together with recording lifecycle`

## Remaining Lifecycle Race Fixes

- Synchronized `ARSessionManager.onFrameCaptured` registration and callback snapshotting with an internal lock, so AR delegate reads cannot race `ContentView` registration or removal.
- Replaced the shared Boolean recorder gate with a lock-protected per-scan generation token. Callback queue submission remains inside the gate lock, and stale callbacks from an earlier scan are rejected after a fast restart.
- Moved the successful Photos-save `didSaveVideo` state mutation and its reset onto the main queue.

## Verification

- `git diff --check` passed.
- `git show --check HEAD` passed.
- `swiftc -parse Sources/AR/ARSessionManager.swift Sources/ContentView.swift` passed.
- Full Xcode build was not run because the full Xcode/iOS SDK is unavailable on this Mac.
