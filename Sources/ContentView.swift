import SwiftUI
import CoreVideo

struct ContentView: View {
    private enum Screen {
        case idle
        case scanning
    }

    @State private var screen: Screen = .idle
    @State private var didSaveVideo = false
    @StateObject private var sessionManager = ARSessionManager()
    private let recorder = VideoRecorder()

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
        sessionManager.onFrameCaptured = { pixelBuffer, timestamp in
            if !self.recorder.isRecording {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                _ = try? self.recorder.startRecording(width: width, height: height)
            }
            self.recorder.appendFrame(pixelBuffer, timestamp: timestamp)
        }
        sessionManager.start()
        screen = .scanning
    }

    private func stopScan() {
        sessionManager.stop()
        sessionManager.onFrameCaptured = nil
        recorder.stopRecording { result in
            if case .success(let url) = result {
                PhotoSaver.save(videoURL: url) { saveResult in
                    try? FileManager.default.removeItem(at: url)
                    guard case .success = saveResult else { return }
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
