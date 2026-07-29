import Foundation

final class RecordingFrameGate {
    private let lock = NSLock()
    private var acceptsFrames = false
    private var frameInFlight = false
    private var generation: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        acceptsFrames = true
        frameInFlight = false
        return generation
    }

    func end() {
        lock.lock()
        acceptsFrames = false
        frameInFlight = false
        generation &+= 1
        lock.unlock()
    }

    func tryAcceptFrame(for generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptsFrames, self.generation == generation, !frameInFlight else { return false }
        frameInFlight = true
        return true
    }

    func completeFrame() {
        lock.lock()
        frameInFlight = false
        lock.unlock()
    }
}
