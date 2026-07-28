import XCTest
import AVFoundation
@testable import CoverageScout

final class VideoRecorderTests: XCTestCase {
    func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        return pixelBuffer!
    }

    func test_recordThreeFrames_producesNonEmptyFile() throws {
        let recorder = VideoRecorder()
        let url = try recorder.startRecording(width: 64, height: 64)

        for i in 0..<3 {
            let buffer = makePixelBuffer(width: 64, height: 64)
            recorder.appendFrame(buffer, timestamp: CMTime(value: Int64(i), timescale: 30))
        }

        let expectation = expectation(description: "stopRecording completes")
        var resultURL: URL?
        recorder.stopRecording { result in
            if case .success(let outputURL) = result {
                resultURL = outputURL
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(resultURL, url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 0)

        try? FileManager.default.removeItem(at: url)
    }

    func test_startRecordingTwice_throws() throws {
        let recorder = VideoRecorder()
        _ = try recorder.startRecording(width: 64, height: 64)
        XCTAssertThrowsError(try recorder.startRecording(width: 64, height: 64))
    }
}
