import AVFoundation
import Foundation
import os

final class RecordingFramePacer {
    private static let logger = Logger(subsystem: "com.diebraga.CoverageScout", category: "RecordingFramePacer")

    private let lock = NSLock()
    private let frameRate: Int32
    private var acceptsFrames = false
    private var frameInFlight = false
    private var generation: UInt64 = 0
    private var firstSourceTimestamp: CMTime?
    private var lastAcceptedElapsed: CMTime?

    init(frameRate: Int32 = 30) {
        self.frameRate = frameRate
    }

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        acceptsFrames = true
        frameInFlight = false
        firstSourceTimestamp = nil
        lastAcceptedElapsed = nil
        Self.logger.notice("begin generation=\(self.generation)")
        return generation
    }

    func end() {
        lock.lock()
        acceptsFrames = false
        frameInFlight = false
        firstSourceTimestamp = nil
        lastAcceptedElapsed = nil
        generation &+= 1
        Self.logger.notice("end generation=\(self.generation)")
        lock.unlock()
    }

    /// Returns the frame's true elapsed time since the recording started, or nil to
    /// drop it. The output timestamp is real elapsed time, not an artificial fixed
    /// increment — a frame dropped while the recorder catches up must NOT compress
    /// the real time gap into a single 1/frameRate tick, or the saved video plays
    /// back as jump cuts instead of the real motion (confirmed bug, fixed here).
    func offerFrame(for generation: UInt64, sourceTimestamp: CMTime) -> CMTime? {
        lock.lock()
        defer { lock.unlock() }

        guard acceptsFrames, self.generation == generation else {
            Self.logger.debug("reject reason=wrong-generation-or-inactive offered-gen=\(generation) current-gen=\(self.generation) accepts=\(self.acceptsFrames)")
            return nil
        }
        guard !frameInFlight else {
            Self.logger.debug("reject reason=frame-in-flight")
            return nil
        }

        if firstSourceTimestamp == nil {
            firstSourceTimestamp = sourceTimestamp
        }
        let elapsed = CMTimeSubtract(sourceTimestamp, firstSourceTimestamp!)

        let minimumInterval = CMTime(value: 1, timescale: frameRate)
        if let lastAcceptedElapsed, CMTimeSubtract(elapsed, lastAcceptedElapsed) < minimumInterval {
            Self.logger.debug("reject reason=too-soon elapsed=\(elapsed.seconds, format: .fixed(precision: 3)) lastAccepted=\(lastAcceptedElapsed.seconds, format: .fixed(precision: 3))")
            return nil
        }

        let gapFromLast = lastAcceptedElapsed.map { CMTimeSubtract(elapsed, $0).seconds } ?? 0
        lastAcceptedElapsed = elapsed
        frameInFlight = true
        Self.logger.debug("accept elapsed=\(elapsed.seconds, format: .fixed(precision: 3)) gapFromLast=\(gapFromLast, format: .fixed(precision: 3))")
        return elapsed
    }

    func completeFrame() {
        lock.lock()
        frameInFlight = false
        lock.unlock()
    }
}
