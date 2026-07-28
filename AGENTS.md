# Coverage Scout

Native iOS app (Swift/SwiftUI/RealityKit/ARKit) that gives live LiDAR-based
scan coverage feedback while capturing a room — like Scaniverse's coverage
overlay — so the user knows what still needs better coverage before they stop
recording. The app's only output is a plain `.mov` video; it does no
reconstruction itself.

That video feeds into the separate `3d-reconstructions` pipeline
(ffmpeg → COLMAP → Brush) unchanged, dropped into that project's
`<house>/<room>/raw/` folder exactly like any other capture.

## Status

Design only — no Xcode project yet. Full design, including the coverage
voxel-grid algorithm, thresholds, rendering approach, and recording strategy,
is in
[`docs/superpowers/specs/2026-07-28-coverage-scout-design.md`](docs/superpowers/specs/2026-07-28-coverage-scout-design.md).
Read that before implementing — this file only tracks things worth knowing
across sessions; the spec has the actual design.

## Key constraints (do not repeat these mistakes)

- **Requires a physical LiDAR iPhone** (12 Pro or later "Pro"/"Pro Max").
  ARKit's scene reconstruction needs the LiDAR scanner.
- **Cannot be tested on macOS or the iOS Simulator.** ARKit (including scene
  reconstruction) has no Simulator support and no Mac Catalyst support — it's
  tied to the real camera + motion coprocessor + LiDAR stack. All testing is
  on-device.
- **Dev loop:** build from Xcode to the device over USB the first time, then
  enable wireless deployment (Xcode → Window → Devices and Simulators →
  "Connect via network") so later rebuilds don't need the cable.
- **Free Apple ID installs expire after 7 days** and need a rebuild/reinstall
  from Xcode to renew — not a bug, just how personal-device signing works
  without a paid ($99/yr) developer account.
- **Camera is exclusively locked to one session at a time** — recording
  reuses the running `ARSession`'s own frames (`ARFrame.capturedImage`)
  rather than opening a second `AVCaptureSession`.
- **`CoverageScout.xcodeproj` is generated, not committed.** Run `xcodegen generate` once after cloning (or after editing `project.yml`) before opening the project in Xcode.
