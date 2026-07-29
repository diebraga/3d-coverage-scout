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
