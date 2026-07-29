import AVFoundation
import Foundation

final class RecordingFramePacer {
    private let lock = NSLock()
    private let frameRate: Int32
    private var acceptsFrames = false
    private var frameInFlight = false
    private var generation: UInt64 = 0
    private var firstSourceTimestamp: CMTime?
    private var nextOutputFrame: Int64 = 0

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
        nextOutputFrame = 0
        return generation
    }

    func end() {
        lock.lock()
        acceptsFrames = false
        frameInFlight = false
        firstSourceTimestamp = nil
        generation &+= 1
        lock.unlock()
    }

    func offerFrame(for generation: UInt64, sourceTimestamp: CMTime) -> CMTime? {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsFrames, self.generation == generation, !frameInFlight else { return nil }

        if firstSourceTimestamp == nil {
            firstSourceTimestamp = sourceTimestamp
        } else if let firstSourceTimestamp {
            let elapsed = CMTimeSubtract(sourceTimestamp, firstSourceTimestamp)
            let nextFrameTime = CMTime(value: nextOutputFrame, timescale: frameRate)
            guard elapsed >= nextFrameTime else { return nil }
        }

        let outputTimestamp = CMTime(value: nextOutputFrame, timescale: frameRate)
        nextOutputFrame += 1
        frameInFlight = true
        return outputTimestamp
    }

    func completeFrame() {
        lock.lock()
        frameInFlight = false
        lock.unlock()
    }
}
