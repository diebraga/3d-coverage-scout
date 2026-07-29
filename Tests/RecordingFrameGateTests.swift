import XCTest
@testable import CoverageScout

final class RecordingFrameGateTests: XCTestCase {
    func test_dropsFrameWhileOneIsInFlight() {
        let gate = RecordingFrameGate()
        let generation = gate.begin()

        XCTAssertTrue(gate.tryAcceptFrame(for: generation))
        XCTAssertFalse(gate.tryAcceptFrame(for: generation))

        gate.completeFrame()
        XCTAssertTrue(gate.tryAcceptFrame(for: generation))
    }

    func test_rejectsOldGenerationAfterEnd() {
        let gate = RecordingFrameGate()
        let generation = gate.begin()

        gate.end()

        XCTAssertFalse(gate.tryAcceptFrame(for: generation))
    }
}
