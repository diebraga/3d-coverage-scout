import AVFoundation

final class VideoRecorder {
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

    func startRecording(width: Int, height: Int) throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }

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
        return url
    }

    func appendFrame(_ pixelBuffer: CVPixelBuffer, timestamp: CMTime) {
        guard isRecording, let writer = assetWriter, let input = videoInput, let adaptor else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: timestamp)
            sessionStarted = true
        }
        guard input.isReadyForMoreMediaData else { return }
        adaptor.append(pixelBuffer, withPresentationTime: timestamp)
    }

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
}
