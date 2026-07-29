import AVFoundation
import os

final class VideoRecorder {
    private static let logger = Logger(subsystem: "com.diebraga.CoverageScout", category: "VideoRecorder")

    enum RecorderError: Error {
        case alreadyRecording
        case notRecording
        case writerSetupFailed
    }

    private(set) var isRecording = false
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    private var outputURL: URL?
    private var appendedFrameCount = 0
    private var droppedNotReadyCount = 0

    func startRecording(width: Int, height: Int) throws -> URL {
        guard !isRecording else {
            Self.logger.error("startRecording rejected: already recording")
            throw RecorderError.alreadyRecording
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw RecorderError.writerSetupFailed
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        // ARFrame.capturedImage is always delivered in the camera sensor's native
        // landscape orientation regardless of how the phone is held. The app is
        // portrait-only, so rotate the output — this is the same mechanism the
        // system Camera app uses for "portrait video" (landscape pixel buffer +
        // a rotation transform in the file's metadata), not a re-encode.
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        guard writer.canAdd(input) else { throw RecorderError.writerSetupFailed }
        writer.add(input)
        guard writer.startWriting() else { throw RecorderError.writerSetupFailed }

        assetWriter = writer
        videoInput = input
        self.adaptor = adaptor
        outputURL = url
        sessionStarted = false
        isRecording = true
        appendedFrameCount = 0
        droppedNotReadyCount = 0
        Self.logger.notice("startRecording width=\(width) height=\(height) url=\(url.lastPathComponent)")
        return url
    }

    func appendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard isRecording, let writer = assetWriter, let input = videoInput, let adaptor else {
            Self.logger.debug("appendFrame ignored: not recording")
            return
        }

        if !sessionStarted {
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
            Self.logger.notice("startSession atSourceTime=\(timestamp.seconds, format: .fixed(precision: 3))")
        }
        guard input.isReadyForMoreMediaData else {
            droppedNotReadyCount += 1
            Self.logger.debug("appendFrame dropped: encoder not ready, totalDropped=\(self.droppedNotReadyCount)")
            return
        }
        adaptor.append(pixelBuffer, withPresentationTime: timestamp)
        appendedFrameCount += 1
        if appendedFrameCount % 30 == 0 {
            Self.logger.debug("appendFrame progress appended=\(self.appendedFrameCount) dropped=\(self.droppedNotReadyCount) at=\(timestamp.seconds, format: .fixed(precision: 3))")
        }
    }

    func stopRecording(completion: @escaping (Result<URL, Error>) -> Void) {
        guard isRecording, let writer = assetWriter, let url = outputURL else {
            Self.logger.error("stopRecording rejected: not recording")
            completion(.failure(RecorderError.notRecording))
            return
        }

        isRecording = false
        videoInput?.markAsFinished()
        Self.logger.notice("stopRecording finishing appended=\(self.appendedFrameCount) dropped=\(self.droppedNotReadyCount)")
        writer.finishWriting { [weak self] in
            let result: Result<URL, Error>
            if writer.status == .completed {
                result = .success(url)
                Self.logger.notice("finishWriting completed url=\(url.lastPathComponent)")
            } else {
                result = .failure(writer.error ?? RecorderError.writerSetupFailed)
                Self.logger.error("finishWriting failed status=\(writer.status.rawValue) error=\(writer.error?.localizedDescription ?? "nil")")
            }

            self?.assetWriter = nil
            self?.videoInput = nil
            self?.adaptor = nil
            self?.sessionStarted = false
            self?.outputURL = nil
            completion(result)
        }
    }
}
