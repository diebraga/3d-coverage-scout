import SwiftUI
import CoreVideo

struct ContentView: View {
    private enum Screen {
        case idle
        case scanning
    }

    private final class RecorderGate {
        let lock = NSLock()
        var acceptsFrames = false
        var generation: UInt64 = 0

        func begin() -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            generation &+= 1
            acceptsFrames = true
            return generation
        }

        func end() {
            lock.lock()
            acceptsFrames = false
            generation &+= 1
            lock.unlock()
        }

        func withAcceptedFrame(for generation: UInt64, _ operation: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard acceptsFrames, self.generation == generation else { return }
            operation()
        }
    }

    @State private var screen: Screen = .idle
    @State private var didSaveVideo = false
    @State private var didFailToSaveVideo = false
    @StateObject private var sessionManager = ARSessionManager()
    private let recorder = VideoRecorder()
    private let recorderQueue = DispatchQueue(label: "coverage-scout.recorder")
    private let recorderGate = RecorderGate()

    var body: some View {
        Group {
            switch screen {
            case .idle:
                IdleStartView(onStart: startScan)
            case .scanning:
                ARCoverageScreen(sessionManager: sessionManager, onStop: stopScan)
            }
        }
        .overlay(alignment: .top) {
            if didSaveVideo {
                Label("Video saved", systemImage: "checkmark.circle.fill")
                    .padding(8)
                    .background(.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 12)
            }
            if didFailToSaveVideo {
                Label("Video could not be saved", systemImage: "exclamationmark.circle.fill")
                    .padding(8)
                    .background(.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(8)
                    .padding(.top, 12)
            }
        }
        .alert("LiDAR required", isPresented: .constant(!sessionManager.isLiDARSupported)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This device doesn't have a LiDAR scanner, which Coverage Scout requires.")
        }
    }

    private func startScan() {
        guard sessionManager.isLiDARSupported else { return }
        didSaveVideo = false
        didFailToSaveVideo = false
        let scanGeneration = recorderGate.begin()
        sessionManager.onFrameCaptured = { pixelBuffer, timestamp in
            self.recorderGate.withAcceptedFrame(for: scanGeneration) {
                self.recorderQueue.async {
                    if !self.recorder.isRecording {
                        let width = CVPixelBufferGetWidth(pixelBuffer)
                        let height = CVPixelBufferGetHeight(pixelBuffer)
                        _ = try? self.recorder.startRecording(width: width, height: height)
                    }
                    self.recorder.appendFrame(pixelBuffer, timestamp: timestamp)
                }
            }
        }
        sessionManager.start()
        screen = .scanning
    }

    private func stopScan() {
        sessionManager.stop()
        recorderGate.end()
        sessionManager.onFrameCaptured = nil

        // ponytail: one serial queue protects the single recorder; split it only if recording throughput requires it.
        recorderQueue.sync {
            recorder.stopRecording { result in
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
        screen = .idle
    }
}

#Preview {
    ContentView()
}
