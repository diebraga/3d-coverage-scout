# Scaniverse Illusion Recording Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Scaniverse-like app-only frosted capture guide, add a recording timer, and make saved raw camera videos smooth and clean.

**Architecture:** Keep `ARSessionManager` and `VoxelGrid` as the AR/coverage source of truth. Replace the red box renderer with a capped frosted incomplete-surface renderer. Add a small recording frame pacer so `VideoRecorder` receives stable 30 fps timestamps without blocking ARKit.

**Tech Stack:** Swift 5, SwiftUI, ARKit, SceneKit, AVFoundation, XCTest, XcodeGen.

## Global Constraints

- The overlay is only app UI guidance. It must never be baked into the saved `.mov`.
- No live Gaussian splat rendering.
- No live textured reconstruction preview.
- No projecting camera frames onto the mesh.
- No on-device reconstruction or "Process Now" flow.
- Overlay refresh: at most 4 times per second.
- Visible frosted nodes: start at 600 maximum.
- New overlay nodes per refresh: start at 120 maximum.
- Removed overlay nodes per refresh: start at 240 maximum.
- Recording output cadence: 30 fps maximum.
- No overlay work should run on every camera frame.
- No writer call should run synchronously on the AR session callback beyond a small gate check.
- Saved video has no overlay, blur, UI, or coverage markers.

---

## File Structure

- `Sources/Recording/RecordingFramePacer.swift`: new pure-Swift cadence gate for recording frames. Owns generation, target fps, next output timestamp, and in-flight state.
- `Tests/RecordingFramePacerTests.swift`: new XCTest file for pacing, timestamps, generation reset, and stale-frame rejection.
- `Sources/Recording/RecordingFrameGate.swift`: remove after replacing it with `RecordingFramePacer`.
- `Tests/RecordingFrameGateTests.swift`: remove after replacing it with pacer tests.
- `Sources/Recording/VideoRecorder.swift`: keep focused on writing frames. Add cleanup/reset after finish so repeated scans do not reuse writer state.
- `Tests/VideoRecorderTests.swift`: add a paced timestamp regression using 30 fps `CMTime`.
- `Sources/ContentView.swift`: wire the pacer into recording, make stop immediate, and add elapsed recording time state.
- `Sources/AR/ARCoverageView.swift`: show `MM:SS` recording timer while recording.
- `Sources/AR/FrostedCoverageOverlayRenderer.swift`: new SceneKit renderer for frosted incomplete coverage nodes.
- `Sources/AR/RedTodoOverlayRenderer.swift`: delete after the frosted renderer is wired.
- `Sources/AR/ARSessionManager.swift`: replace red renderer usage with frosted renderer usage.
- `docs/superpowers/specs/2026-07-28-scaniverse-illusion-recording-design.md`: source spec for requirements.

---

### Task 1: Stable Recording Frame Pacer

**Files:**
- Create: `Sources/Recording/RecordingFramePacer.swift`
- Create: `Tests/RecordingFramePacerTests.swift`
- Delete: `Sources/Recording/RecordingFrameGate.swift`
- Delete: `Tests/RecordingFrameGateTests.swift`

**Interfaces:**
- Produces:
  - `final class RecordingFramePacer`
  - `init(frameRate: Int32 = 30)`
  - `func begin() -> UInt64`
  - `func end()`
  - `func offerFrame(for generation: UInt64, sourceTimestamp: CMTime) -> CMTime?`
  - `func completeFrame()`
- Consumes:
  - `CMTime` from AVFoundation.

- [ ] **Step 1: Write failing pacer tests**

Create `Tests/RecordingFramePacerTests.swift`:

```swift
import XCTest
import AVFoundation
@testable import CoverageScout

final class RecordingFramePacerTests: XCTestCase {
    func test_acceptsFirstFrameAtZeroTimestamp() {
        let pacer = RecordingFramePacer(frameRate: 30)
        let generation = pacer.begin()

        let timestamp = pacer.offerFrame(
            for: generation,
            sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 600)
        )

        XCTAssertEqual(timestamp, CMTime(value: 0, timescale: 30))
    }

    func test_rejectsFrameBeforeNextCadenceTick() {
        let pacer = RecordingFramePacer(frameRate: 30)
        let generation = pacer.begin()

        XCTAssertNotNil(pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 600)))
        pacer.completeFrame()

        let tooSoon = pacer.offerFrame(
            for: generation,
            sourceTimestamp: CMTime(seconds: 10.01, preferredTimescale: 600)
        )

        XCTAssertNil(tooSoon)
    }

    func test_acceptsNextCadenceFrameWithStableOutputTimestamp() {
        let pacer = RecordingFramePacer(frameRate: 30)
        let generation = pacer.begin()

        XCTAssertEqual(
            pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 600)),
            CMTime(value: 0, timescale: 30)
        )
        pacer.completeFrame()

        XCTAssertEqual(
            pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10.04, preferredTimescale: 600)),
            CMTime(value: 1, timescale: 30)
        )
    }

    func test_rejectsWhileFrameIsInFlight() {
        let pacer = RecordingFramePacer(frameRate: 30)
        let generation = pacer.begin()

        XCTAssertNotNil(pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 600)))

        XCTAssertNil(pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10.04, preferredTimescale: 600)))
    }

    func test_rejectsOldGenerationAfterEnd() {
        let pacer = RecordingFramePacer(frameRate: 30)
        let generation = pacer.begin()

        pacer.end()

        XCTAssertNil(pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 600)))
    }

    func test_newGenerationResetsOutputTimestamp() {
        let pacer = RecordingFramePacer(frameRate: 30)
        let firstGeneration = pacer.begin()

        XCTAssertNotNil(pacer.offerFrame(for: firstGeneration, sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 600)))
        pacer.end()

        let secondGeneration = pacer.begin()

        XCTAssertEqual(
            pacer.offerFrame(for: secondGeneration, sourceTimestamp: CMTime(seconds: 20, preferredTimescale: 600)),
            CMTime(value: 0, timescale: 30)
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -quiet -project CoverageScout.xcodeproj -scheme CoverageScout \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  -derivedDataPath /private/tmp/coverage-scout-task1 build
```

Expected: FAIL with `cannot find 'RecordingFramePacer' in scope`.

- [ ] **Step 3: Implement the minimal pacer**

Create `Sources/Recording/RecordingFramePacer.swift`:

```swift
import AVFoundation
import Foundation

final class RecordingFramePacer {
    private let lock = NSLock()
    private let frameRate: Int32
    private var acceptsFrames = false
    private var frameInFlight = false
    private var generation: UInt64 = 0
    private var firstSourceTimestamp: CMTime?
    private var nextOutputFrame: Int64 = 0

    init(frameRate: Int32 = 30) {
        self.frameRate = frameRate
    }

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        acceptsFrames = true
        frameInFlight = false
        firstSourceTimestamp = nil
        nextOutputFrame = 0
        return generation
    }

    func end() {
        lock.lock()
        acceptsFrames = false
        frameInFlight = false
        firstSourceTimestamp = nil
        generation &+= 1
        lock.unlock()
    }

    func offerFrame(for generation: UInt64, sourceTimestamp: CMTime) -> CMTime? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsFrames, self.generation == generation, !frameInFlight else { return nil }

        if firstSourceTimestamp == nil {
            firstSourceTimestamp = sourceTimestamp
        } else if let firstSourceTimestamp {
            let elapsed = CMTimeSubtract(sourceTimestamp, firstSourceTimestamp)
            let nextFrameTime = CMTime(value: nextOutputFrame, timescale: frameRate)
            guard elapsed >= nextFrameTime else { return nil }
        }

        let outputTimestamp = CMTime(value: nextOutputFrame, timescale: frameRate)
        nextOutputFrame += 1
        frameInFlight = true
        return outputTimestamp
    }

    func completeFrame() {
        lock.lock()
        frameInFlight = false
        lock.unlock()
    }
}
```

Delete `Sources/Recording/RecordingFrameGate.swift`.

Delete `Tests/RecordingFrameGateTests.swift`.

- [ ] **Step 4: Regenerate project**

Run:

```bash
xcodegen generate
```

Expected: output includes `Created project at /Users/diegobraga/Downloads/3d-coverage-scout/CoverageScout.xcodeproj`.

- [ ] **Step 5: Run build to verify green**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -quiet -project CoverageScout.xcodeproj -scheme CoverageScout \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  -derivedDataPath /private/tmp/coverage-scout-task1 build
```

Expected: exit code `0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/Recording/RecordingFramePacer.swift Tests/RecordingFramePacerTests.swift
git add -u Sources/Recording/RecordingFrameGate.swift Tests/RecordingFrameGateTests.swift CoverageScout.xcodeproj
git commit -m "Add stable recording frame pacer"
```

---

### Task 2: Wire Pacer, Timer, And Immediate Stop UI

**Files:**
- Modify: `Sources/ContentView.swift`
- Modify: `Sources/AR/ARCoverageView.swift`
- Modify: `Sources/Recording/VideoRecorder.swift`
- Modify: `Tests/VideoRecorderTests.swift`

**Interfaces:**
- Consumes from Task 1:
  - `RecordingFramePacer.begin() -> UInt64`
  - `RecordingFramePacer.end()`
  - `RecordingFramePacer.offerFrame(for:sourceTimestamp:) -> CMTime?`
  - `RecordingFramePacer.completeFrame()`
- Produces:
  - `ARCoverageScreen(recordingElapsedText: String?)`
  - `VideoRecorder.stopRecording(completion:)` resets writer state after finish.

- [ ] **Step 1: Add failing VideoRecorder repeat-use test**

Append this test to `Tests/VideoRecorderTests.swift`:

```swift
    func test_canRecordAgainAfterStopping() throws {
        let recorder = VideoRecorder()

        let firstURL = try recorder.startRecording(width: 64, height: 64)
        recorder.appendFrame(makePixelBuffer(width: 64, height: 64), timestamp: CMTime(value: 0, timescale: 30))

        let firstStop = expectation(description: "first stop")
        recorder.stopRecording { _ in firstStop.fulfill() }
        wait(for: [firstStop], timeout: 5)

        let secondURL = try recorder.startRecording(width: 64, height: 64)
        recorder.appendFrame(makePixelBuffer(width: 64, height: 64), timestamp: CMTime(value: 0, timescale: 30))

        let secondStop = expectation(description: "second stop")
        recorder.stopRecording { _ in secondStop.fulfill() }
        wait(for: [secondStop], timeout: 5)

        XCTAssertNotEqual(firstURL, secondURL)
        try? FileManager.default.removeItem(at: firstURL)
        try? FileManager.default.removeItem(at: secondURL)
    }
```

- [ ] **Step 2: Run build to verify current behavior**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -quiet -project CoverageScout.xcodeproj -scheme CoverageScout \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  -derivedDataPath /private/tmp/coverage-scout-task2 build
```

Expected: if XCTest is not runnable in this environment, build may still pass; keep the test as the regression. If device XCTest is available, run it and expect the test to expose repeat-use state if current writer cleanup is insufficient.

- [ ] **Step 3: Reset VideoRecorder state after finish**

Modify `Sources/Recording/VideoRecorder.swift` `stopRecording` method so the writer state is cleared after `finishWriting`:

```swift
    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording, let writer = assetWriter, let url = outputURL else {
            completion(.failure(RecorderError.notRecording))
            return
        }

        isRecording = false
        videoInput?.markAsFinished()
        writer.finishWriting { [weak self] in
            let result: Result<URL, Error>
            if writer.status == .completed {
                result = .success(url)
            } else {
                result = .failure(writer.error ?? RecorderError.writerSetupFailed)
            }

            self?.assetWriter = nil
            self?.videoInput = nil
            self?.adaptor = nil
            self?.sessionStarted = false
            self?.outputURL = nil
            completion(result)
        }
    }
```

- [ ] **Step 4: Wire pacer and timer in ContentView**

In `Sources/ContentView.swift`, replace:

```swift
    private let recorderGate = RecordingFrameGate()
```

with:

```swift
    @State private var recordingStartedAt: Date?
    @State private var recordingElapsedText: String?
    @State private var recordingTimerTask: Task<Void, Never>?
    private let recorderPacer = RecordingFramePacer(frameRate: 30)
```

Pass the timer text into `ARCoverageScreen`:

```swift
ARCoverageScreen(
    sessionManager: sessionManager,
    isRecording: isRecording,
    recordingElapsedText: recordingElapsedText,
    onToggleRecording: toggleRecording
)
```

Replace `beginRecording()` with:

```swift
    private func beginRecording() {
        let scanGeneration = recorderPacer.begin()
        recordingStartedAt = Date()
        recordingElapsedText = "00:00"
        startRecordingTimer()

        sessionManager.onFrameCaptured = { pixelBuffer, timestamp in
            guard let outputTimestamp = self.recorderPacer.offerFrame(for: scanGeneration, sourceTimestamp: timestamp) else { return }
            self.recorderQueue.async {
                defer { self.recorderPacer.completeFrame() }
                if !self.recorder.isRecording {
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    do {
                        _ = try self.recorder.startRecording(width: width, height: height)
                    } catch {
                        DispatchQueue.main.async {
                            self.didFailToSaveVideo = true
                        }
                        return
                    }
                }
                self.recorder.appendFrame(pixelBuffer, timestamp: outputTimestamp)
            }
        }
        isRecording = true
        AudioServicesPlaySystemSound(1117)
    }
```

Replace the start of `stopRecording()` with:

```swift
    private func stopRecording() {
        guard !isStopping else { return }
        isStopping = true
        isRecording = false
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingStartedAt = nil
        recordingElapsedText = nil
        recorderPacer.end()
        sessionManager.onFrameCaptured = nil
```

Do not call `sessionManager.stop()` in `stopRecording()`. The user should be able to stop recording without tearing down AR until the screen returns to idle.

Add this helper:

```swift
    private func startRecordingTimer() {
        recordingTimerTask?.cancel()
        recordingTimerTask = Task {
            while !Task.isCancelled {
                guard let recordingStartedAt else { return }
                let elapsed = max(0, Int(Date().timeIntervalSince(recordingStartedAt)))
                let minutes = elapsed / 60
                let seconds = elapsed % 60
                await MainActor.run {
                    recordingElapsedText = String(format: "%02d:%02d", minutes, seconds)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
```

Keep the existing `PhotoSaver.save` block, but set `screen = .idle` in the writer completion before the Photos save begins:

```swift
        recorderQueue.async {
            recorder.stopRecording { result in
                DispatchQueue.main.async {
                    self.isStopping = false
                    self.screen = .idle
                    self.sessionManager.stop()
                }
                guard case .success(let url) = result else {
                    DispatchQueue.main.async {
                        self.didFailToSaveVideo = true
                    }
                    return
                }
                PhotoSaver.save(videoURL: url) { saveResult in
                    guard case .success = saveResult else {
                        DispatchQueue.main.async {
                            self.didFailToSaveVideo = true
                        }
                        return
                    }
                    try? FileManager.default.removeItem(at: url)
                    DispatchQueue.main.async {
                        self.didSaveVideo = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            self.didSaveVideo = false
                        }
                    }
                }
            }
        }
```

- [ ] **Step 5: Show timer in ARCoverageScreen**

Modify the `ARCoverageScreen` signature in `Sources/AR/ARCoverageView.swift`:

```swift
struct ARCoverageScreen: View {
    @ObservedObject var sessionManager: ARSessionManager
    let isRecording: Bool
    let recordingElapsedText: String?
    let onToggleRecording: () -> Void
```

Add timer display above the scan quality text:

```swift
                        if let recordingElapsedText {
                            Text(recordingElapsedText)
                                .font(.system(.headline, design: .monospaced))
                                .padding(8)
                                .background(.black.opacity(0.7))
                                .foregroundColor(.green)
                                .cornerRadius(8)
                        }
```

- [ ] **Step 6: Run build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -quiet -project CoverageScout.xcodeproj -scheme CoverageScout \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  -derivedDataPath /private/tmp/coverage-scout-task2 build
```

Expected: exit code `0`.

- [ ] **Step 7: Commit**

```bash
git add Sources/ContentView.swift Sources/AR/ARCoverageView.swift Sources/Recording/VideoRecorder.swift Tests/VideoRecorderTests.swift
git commit -m "Stabilize recording cadence and timer"
```

---

### Task 3: Frosted App-Only Coverage Overlay

**Files:**
- Create: `Sources/AR/FrostedCoverageOverlayRenderer.swift`
- Modify: `Sources/AR/ARSessionManager.swift`
- Delete: `Sources/AR/RedTodoOverlayRenderer.swift`

**Interfaces:**
- Consumes:
  - `VoxelGrid.incompleteSamples(limit:near:) -> [VoxelOverlaySample]`
  - `VoxelCoordinate`
- Produces:
  - `final class FrostedCoverageOverlayRenderer`
  - `static let maxVisibleNodes = 600`
  - `func update(samples: [VoxelOverlaySample])`
  - `let rootNode: SCNNode`

- [ ] **Step 1: Create frosted renderer**

Create `Sources/AR/FrostedCoverageOverlayRenderer.swift`:

```swift
import SceneKit
import UIKit

final class FrostedCoverageOverlayRenderer {
    static let maxVisibleNodes = 600
    static let maxAddsPerUpdate = 120
    static let maxRemovesPerUpdate = 240

    let rootNode = SCNNode()
    private var nodesByCoordinate: [VoxelCoordinate: SCNNode] = [:]
    private let material: SCNMaterial = {
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(white: 0.86, alpha: 0.34)
        material.emission.contents = UIColor(white: 0.55, alpha: 0.18)
        material.lightingModel = .constant
        material.blendMode = .alpha
        material.isDoubleSided = true
        material.writesToDepthBuffer = false
        return material
    }()

    func update(samples: [VoxelOverlaySample]) {
        let capped = Array(samples.prefix(Self.maxVisibleNodes))
        let wanted = Set(capped.map(\.coordinate))

        var removed = 0
        for coordinate in nodesByCoordinate.keys where !wanted.contains(coordinate) {
            guard removed < Self.maxRemovesPerUpdate else { break }
            nodesByCoordinate.removeValue(forKey: coordinate)?.removeFromParentNode()
            removed += 1
        }

        var added = 0
        for sample in capped where nodesByCoordinate[sample.coordinate] == nil {
            guard added < Self.maxAddsPerUpdate else { break }
            let node = makeNode(at: sample.center)
            nodesByCoordinate[sample.coordinate] = node
            rootNode.addChildNode(node)
            added += 1
        }
    }

    private func makeNode(at center: SIMD3<Float>) -> SCNNode {
        let geometry = SCNBox(width: 0.12, height: 0.12, length: 0.12, chamferRadius: 0.02)
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.simdPosition = center
        node.opacity = 0.85
        return node
    }
}
```

- [ ] **Step 2: Wire renderer into ARSessionManager**

In `Sources/AR/ARSessionManager.swift`, replace:

```swift
    private let redOverlayRenderer = RedTodoOverlayRenderer()
```

with:

```swift
    private let coverageOverlayRenderer = FrostedCoverageOverlayRenderer()
```

Replace:

```swift
        sceneView.scene.rootNode.addChildNode(redOverlayRenderer.rootNode)
```

with:

```swift
        sceneView.scene.rootNode.addChildNode(coverageOverlayRenderer.rootNode)
```

Replace:

```swift
            voxelGrid.incompleteSamples(limit: RedTodoOverlayRenderer.maxVisibleNodes, near: cameraPosition)
```

with:

```swift
            voxelGrid.incompleteSamples(limit: FrostedCoverageOverlayRenderer.maxVisibleNodes, near: cameraPosition)
```

Replace:

```swift
            self?.redOverlayRenderer.update(samples: samples)
```

with:

```swift
            self?.coverageOverlayRenderer.update(samples: samples)
```

- [ ] **Step 3: Delete red renderer**

Delete `Sources/AR/RedTodoOverlayRenderer.swift`.

- [ ] **Step 4: Regenerate project**

Run:

```bash
xcodegen generate
```

Expected: output includes `Created project at /Users/diegobraga/Downloads/3d-coverage-scout/CoverageScout.xcodeproj`.

- [ ] **Step 5: Run build**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -quiet -project CoverageScout.xcodeproj -scheme CoverageScout \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM='' \
  -derivedDataPath /private/tmp/coverage-scout-task3 build
```

Expected: exit code `0`.

- [ ] **Step 6: Commit**

```bash
git add Sources/AR/FrostedCoverageOverlayRenderer.swift Sources/AR/ARSessionManager.swift CoverageScout.xcodeproj
git add -u Sources/AR/RedTodoOverlayRenderer.swift
git commit -m "Add frosted coverage overlay"
```

---

### Task 4: Device Build, Install, And Manual Validation

**Files:**
- Modify: `.superpowers/sdd/2026-07-28-coverage-scout/progress.md`

**Interfaces:**
- Consumes the completed app from Tasks 1-3.
- Produces manual validation notes in the local SDD ledger.

- [ ] **Step 1: Build for connected iPhone**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -quiet -project CoverageScout.xcodeproj -scheme CoverageScout \
  -destination 'platform=iOS,id=00008150-0008594C0282401C' \
  ENABLE_DEBUG_DYLIB=NO DEVELOPMENT_TEAM=VHWZ5GA82G \
  -derivedDataPath /private/tmp/coverage-scout-device-build-scanillusion build
```

Expected: exit code `0`. Do not add `-allowProvisioningUpdates`.

- [ ] **Step 2: Install on iPhone**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun devicectl device install app \
  --device CEC971B1-EED6-5D1C-AD78-7B0FAC127C40 \
  /private/tmp/coverage-scout-device-build-scanillusion/Build/Products/Debug-iphoneos/CoverageScout.app
```

Expected: output includes `App installed` and `bundleID: com.diebraga.CoverageScout`.

- [ ] **Step 3: Launch on iPhone**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun devicectl device process launch --terminate-existing \
  --device CEC971B1-EED6-5D1C-AD78-7B0FAC127C40 \
  com.diebraga.CoverageScout
```

Expected: output includes `Launched application with com.diebraga.CoverageScout bundle identifier`.

- [ ] **Step 4: Ask user to perform manual validation**

Ask the user to test:

```text
1. Start scan.
2. Confirm frosted/soft overlay appears over not-yet-covered surfaces.
3. Move around and confirm covered areas clear back to normal camera.
4. Start recording and confirm timer counts.
5. Move for 20-30 seconds.
6. Tap stop and confirm the UI stops recording quickly.
7. Open the saved video in Photos.
8. Confirm the saved video has no overlay/blur/UI.
9. Confirm the saved video plays smoothly through movement.
```

- [ ] **Step 5: Update local ledger**

Append this to `.superpowers/sdd/2026-07-28-coverage-scout/progress.md`:

```markdown
## Scaniverse Illusion Recording Follow-Up

- Spec: `docs/superpowers/specs/2026-07-28-scaniverse-illusion-recording-design.md`
- Plan: `docs/superpowers/plans/2026-07-28-scaniverse-illusion-recording.md`
- Device build command excludes `-allowProvisioningUpdates`.
- Manual validation pending:
  - frosted app-only overlay smooth
  - covered areas clear
  - timer counts
  - stop responds quickly
  - saved video has no overlay
  - saved video plays smoothly
```

- [ ] **Step 6: Commit tracked validation notes if any**

The `.superpowers` ledger is gitignored, so there may be no tracked changes. Run:

```bash
git status --short
```

Expected: no unexpected tracked changes. If only ignored ledger changed, do not commit it.

---

## Final Verification Checklist

- `xcodegen generate` completed after source file add/delete tasks.
- iPhoneOS compile-only build exits `0`.
- Connected iPhone build exits `0`.
- App installs and launches on the iPhone.
- User confirms saved video is clean.
- User confirms saved video movement is smoother than the frame-gated build.
- User confirms stop UI responds promptly.
- User confirms frosted overlay is acceptable as the first Scaniverse-like illusion.
