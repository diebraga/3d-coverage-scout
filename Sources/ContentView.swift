import SwiftUI
import CoreVideo
import AudioToolbox
import os

struct ContentView: View {
    private static let logger = Logger(subsystem: "com.diebraga.CoverageScout", category: "ContentView")

    private enum Screen {
        case idle
        case scanning
    }

    @State private var screen: Screen = .idle
    @State private var isRecording = false
    @State private var isStopping = false
    @State private var didSaveVideo = false
    @State private var didFailToSaveVideo = false
    @StateObject private var sessionManager = ARSessionManager()
    @State private var recordingStartedAt: Date?
    @State private var recordingElapsedText: String?
    @State private var recordingTimerTask: Task<Void, Never>?
    private let recorder = VideoRecorder()
    private let recorderQueue = DispatchQueue(label: "coverage-scout.recorder")
    private let recorderPacer = RecordingFramePacer(frameRate: 30)

    var body: some View {
        Group {
            switch screen {
            case .idle:
                IdleStartView(onStart: openCamera)
            case .scanning:
                ARCoverageScreen(
                    sessionManager: sessionManager,
                    isRecording: isRecording,
                    recordingElapsedText: recordingElapsedText,
                    onToggleRecording: toggleRecording
                )
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

    private func openCamera() {
        Self.logger.notice("tap openCamera lidarSupported=\(sessionManager.isLiDARSupported)")
        guard sessionManager.isLiDARSupported else { return }
        didSaveVideo = false
        didFailToSaveVideo = false
        sessionManager.start()
        screen = .scanning
    }

    private func toggleRecording() {
        Self.logger.notice("tap toggleRecording currentlyRecording=\(self.isRecording) isStopping=\(self.isStopping)")
        if isRecording {
            stopRecording()
        } else {
            beginRecording()
        }
    }

    private func beginRecording() {
        let scanGeneration = recorderPacer.begin()
        Self.logger.notice("beginRecording generation=\(scanGeneration)")
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
        // ponytail: well-known system sound ID matching the Camera app's own
        // begin-recording chime; swap the ID if it doesn't sound right on-device.
        AudioServicesPlaySystemSound(1117)
    }

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

    private func stopRecording() {
        guard !isStopping else {
            Self.logger.notice("stopRecording ignored: already stopping")
            return
        }
        Self.logger.notice("stopRecording begin")
        isStopping = true
        isRecording = false
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        recordingStartedAt = nil
        recordingElapsedText = nil
        recorderPacer.end()
        sessionManager.onFrameCaptured = nil

        // ponytail: one serial queue protects the single recorder; split it only if recording throughput requires it.
        recorderQueue.async {
            recorder.stopRecording { result in
                Self.logger.notice("recorder.stopRecording completion reached")
                DispatchQueue.main.async {
                    self.isStopping = false
                    self.screen = .idle
                    self.sessionManager.stop()
                }
                guard case .success(let url) = result else {
                    Self.logger.error("stopRecording failed to produce a file")
                    DispatchQueue.main.async {
                        self.didFailToSaveVideo = true
                    }
                    return
                }
                PhotoSaver.save(videoURL: url) { saveResult in
                    guard case .success = saveResult else {
                        Self.logger.error("PhotoSaver.save failed")
                        DispatchQueue.main.async {
                            self.didFailToSaveVideo = true
                        }
                        return
                    }
                    Self.logger.notice("PhotoSaver.save succeeded")
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
    }
}

#Preview {
    ContentView()
}
