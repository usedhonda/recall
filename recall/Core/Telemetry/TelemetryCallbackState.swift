import Foundation

/// URLSession delegates and async persistence finish on different executors.
/// The OS completion handler is released only after both events and all durable
/// callback transactions have finished, including transport failures.
final class TelemetryCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    private var pending = 0
    private var eventsFinished = false

    var isProcessing: Bool {
        lock.lock(); defer { lock.unlock() }; return pending > 0
    }

    func append(_ data: Data, taskID: Int) {
        lock.lock(); defer { lock.unlock() }
        bodies[taskID, default: Data()].append(data)
    }

    func beginCompletion(_ taskID: Int) -> Data {
        lock.lock(); defer { lock.unlock() }
        pending += 1
        return bodies.removeValue(forKey: taskID) ?? Data()
    }

    func endCompletion() {
        lock.lock(); defer { lock.unlock() }; pending -= 1
    }

    func finishEvents() {
        lock.lock(); defer { lock.unlock() }; eventsFinished = true
    }

    func consumeFinished() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard eventsFinished && pending == 0 else { return false }
        eventsFinished = false
        return true
    }
}
