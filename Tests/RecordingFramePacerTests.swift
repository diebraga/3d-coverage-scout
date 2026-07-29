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

    func test_acceptsNextCadenceFrameWithRealElapsedTimestamp() {
        let pacer = RecordingFramePacer(frameRate: 30)
        let generation = pacer.begin()

        XCTAssertEqual(
            pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 600)),
            CMTime(value: 0, timescale: 30)
        )
        pacer.completeFrame()

        // Real elapsed time (0.04s) is returned as-is — not snapped to a fixed
        // frame-count grid — so the saved video's timing matches real motion.
        // Accuracy wider than 1/600s: CMTime(seconds: 10.04, ...) isn't exactly
        // representable in binary floating point, so its rounding alone can land
        // outside a too-tight tolerance — that's a test-input artifact, not a
        // claim about the pacer's own precision.
        let accepted = pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10.04, preferredTimescale: 600))
        XCTAssertEqual(accepted?.seconds ?? -1, 0.04, accuracy: 0.01)
    }

    func test_recordsTrueElapsedTimeAcrossDroppedFrames() {
        let pacer = RecordingFramePacer(frameRate: 30)
        let generation = pacer.begin()

        // First frame accepted, deliberately left in-flight (no completeFrame call)
        // to simulate the recorder queue falling behind.
        XCTAssertNotNil(pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10, preferredTimescale: 600)))

        // Several frames arrive while still in-flight — all must be dropped, not
        // queued or compressed.
        XCTAssertNil(pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10.1, preferredTimescale: 600)))
        XCTAssertNil(pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10.3, preferredTimescale: 600)))

        pacer.completeFrame()

        // The next accepted frame must carry the TRUE elapsed gap (0.5s), not a
        // single 1/30s tick — this is the bug this fix addresses.
        let accepted = pacer.offerFrame(for: generation, sourceTimestamp: CMTime(seconds: 10.5, preferredTimescale: 600))
        XCTAssertEqual(accepted?.seconds ?? -1, 0.5, accuracy: 0.01)
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
