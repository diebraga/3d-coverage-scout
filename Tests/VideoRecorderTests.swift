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
}
