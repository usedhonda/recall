import Foundation

/// All engine instances share the audio teardown barrier. An engine replacement must not
/// reset the ring/VAD or acquire the single capture reservation before the old owner finishes.
@MainActor
final class AudioFinalizationQueue {
    static let shared = AudioFinalizationQueue()
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        revision &+= 1
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        return task
    }

    func wait() async {
        // Work can be appended during suspension (for example a stop during admission).
        // A revision check drains the entire boundary rather than only its initial tail.
        var observed = revision
        while let task = tail {
            await task.value
            if observed == revision { return }
            observed = revision
        }
    }

    /// Join only the barrier that existed when called. Processing work uses this
    /// variant so a concurrent stop cannot append a task that it would then await.
    func waitExisting() async {
        let existing = tail
        await existing?.value
    }

    private var revision: UInt64 = 0
}

/// Each suspended audio operation carries this token. Stop invalidates it synchronously;
/// cancellation alone cannot prevent a successful old admission/VAD await from returning.
@MainActor
final class AudioCaptureGeneration {
    private(set) var token = UUID()
    func invalidate() { token = UUID() }
    func accepts(_ candidate: UUID) -> Bool { candidate == token }
}

/// Small production ownership seam used by the engine and deterministic lifecycle tests.
/// A stop invalidates the current generation before any suspension; queued work retains
/// its owner until the operation completes, even when the originating engine is released.
@MainActor
final class AudioLifecycleOwnership {
    let queue: AudioFinalizationQueue
    let generation = AudioCaptureGeneration()

    init(queue: AudioFinalizationQueue) { self.queue = queue }

    func beginStop() -> UUID {
        generation.invalidate()
        return generation.token
    }

    func accepts(_ token: UUID) -> Bool { generation.accepts(token) }

    func acquire<Resource>(generation token: UUID,
                           reserve: () async -> Resource?,
                           release: (Resource) -> Void) async -> Resource? {
        guard accepts(token), !Task.isCancelled else { return nil }
        guard let resource = await reserve() else { return nil }
        guard accepts(token), !Task.isCancelled else { release(resource); return nil }
        return resource
    }

    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        queue.enqueue(operation)
    }
}

/// Owns a detached chunk until its one finalization completes. Multiple callers
/// join the same task rather than finishing/releasing the resource twice.
@MainActor
final class AudioFinalizationOwner<Value> {
    private let value: Value
    private let release: () -> Void
    private var task: Task<Void, Never>?

    init(_ value: Value, release: @escaping () -> Void) {
        self.value = value
        self.release = release
    }

    func finish(_ operation: @escaping @MainActor (Value) async -> Void) async {
        if let task { await task.value; return }
        let value = value
        let release = release
        let work = Task { @MainActor in
            defer { release() }
            await operation(value)
        }
        task = work
        await work.value
    }
}

/// Defines the accepted-tap boundary under one lock, including an already running
/// callback. Closing precedes the ring drain; callbacks from an old tap cannot
/// append after close or contaminate a replacement tap's ring.
final class AudioTapAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UUID?

    func open() -> UUID {
        lock.lock(); defer { lock.unlock() }
        let next = UUID(); token = next; return next
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        token = nil
    }

    func write(_ samples: [Float], token candidate: UUID, to ring: RingBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard token == candidate else { return }
        ring.write(samples)
    }
}
