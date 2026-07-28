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
        recorderGate.lock.lock()
        recorderGate.acceptsFrames = true
        recorderGate.lock.unlock()
        sessionManager.onFrameCaptured = { pixelBuffer, timestamp in
            self.recorderGate.lock.lock()
            guard self.recorderGate.acceptsFrames else {
                self.recorderGate.lock.unlock()
                return
            }
            self.recorderQueue.async {
                if !self.recorder.isRecording {
                    let width = CVPixelBufferGetWidth(pixelBuffer)
                    let height = CVPixelBufferGetHeight(pixelBuffer)
                    _ = try? self.recorder.startRecording(width: width, height: height)
                }
                self.recorder.appendFrame(pixelBuffer, timestamp: timestamp)
            }
            self.recorderGate.lock.unlock()
        }
        sessionManager.start()
        screen = .scanning
    }

    private func stopScan() {
        sessionManager.stop()
        recorderGate.lock.lock()
        recorderGate.acceptsFrames = false
        sessionManager.onFrameCaptured = nil
        recorderGate.lock.unlock()

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
                    didSaveVideo = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        didSaveVideo = false
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
