import Foundation

/// Thread-safe circular buffer for audio samples.
/// Uses NSLock (not actor) because it is called from the realtime audio thread.
/// Sendable because all access is protected by NSLock.
final class RingBuffer: @unchecked Sendable {
    private var buffer: [Float]
    private let capacity: Int
    private var writeIndex: Int = 0
    private var filled: Int = 0
    private let lock = NSLock()
    private var _lastWriteTime: Date = Date()
    /// Every sample ever written, counted. Lets a reader ask for exactly the audio it
    /// has not seen yet, which a speech model needs: it carries state from one window
    /// to the next, so repeating or skipping audio corrupts its idea of the sentence.
    private var _totalWritten: Int = 0

    /// Initialize with capacity in samples.
    /// The default is one second at the 48 kHz the microphone delivers, not three seconds.
    init(capacity: Int = 48_000) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    /// Timestamp of the most recent write (for watchdog monitoring).
    var lastWriteTime: Date {
        lock.lock()
        defer { lock.unlock() }
        return _lastWriteTime
    }

    /// Append samples to the ring buffer, overwriting oldest data when full.
    func write(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }

        _lastWriteTime = Date()
        _totalWritten += samples.count
        let count = samples.count
        if count >= capacity {
            // Incoming data is larger than buffer; keep only the tail
            let offset = count - capacity
            buffer = Array(samples[offset...])
            writeIndex = 0
            filled = capacity
            return
        }

        let spaceToEnd = capacity - writeIndex
        if count <= spaceToEnd {
            buffer.replaceSubrange(writeIndex..<(writeIndex + count), with: samples)
        } else {
            // Wrap around
            buffer.replaceSubrange(writeIndex..<capacity, with: samples[0..<spaceToEnd])
            let remaining = count - spaceToEnd
            buffer.replaceSubrange(0..<remaining, with: samples[spaceToEnd..<count])
        }

        writeIndex = (writeIndex + count) % capacity
        filled = min(filled + count, capacity)
    }

    /// How many samples have been written since the buffer was created.
    var totalWritten: Int {
        lock.lock()
        defer { lock.unlock() }
        return _totalWritten
    }

    /// Everything written after `index`, plus the index to pass in next time. A reader
    /// that falls behind further than the buffer holds gets the oldest audio still
    /// present rather than a gap it cannot see.
    func read(after index: Int) -> (samples: [Float], nextIndex: Int) {
        let result = readAfter(index)
        return (result.samples, result.nextIndex)
    }

    /// As `read(after:)`, also saying how many samples were overwritten before the reader
    /// came back (zero when it kept up). The count, the samples and the next index are all
    /// taken under one lock: releasing it in between let the tap write a few samples that
    /// were returned but not accounted for, so the next read repeated them and skipped others.
    func readAfter(_ index: Int) -> (samples: [Float], nextIndex: Int, skipped: Int) {
        lock.lock()
        defer { lock.unlock() }
        let total = _totalWritten
        let oldestHeld = total - filled
        let start = max(index, oldestHeld)
        let skipped = max(0, oldestHeld - index)
        let wanted = total - start
        guard wanted > 0 else { return ([], total, skipped) }
        return (lastLocked(wanted), total, skipped)
    }

    /// Read the last N seconds of samples from the buffer.
    func read(lastSeconds seconds: TimeInterval, sampleRate: Int = 16_000) -> [Float] {
        let count = min(Int(seconds * Double(sampleRate)), filled)
        return read(lastSamples: count)
    }

    /// Read the last N samples from the buffer.
    func read(lastSamples count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return lastLocked(count)
    }

    /// The last N samples together with the index just past them, taken under one lock so
    /// that a reader continuing with `read(after:)` neither repeats nor skips a sample.
    func readLast(_ count: Int) -> (samples: [Float], endIndex: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (lastLocked(count), _totalWritten)
    }

    private func lastLocked(_ count: Int) -> [Float] {
        let available = min(count, filled)
        guard available > 0 else { return [] }

        var result = [Float](repeating: 0, count: available)
        let startIndex = (writeIndex - available + capacity) % capacity

        if startIndex + available <= capacity {
            result.replaceSubrange(0..<available, with: buffer[startIndex..<(startIndex + available)])
        } else {
            // Wrap around
            let firstPart = capacity - startIndex
            result.replaceSubrange(0..<firstPart, with: buffer[startIndex..<capacity])
            let secondPart = available - firstPart
            result.replaceSubrange(firstPart..<available, with: buffer[0..<secondPart])
        }

        return result
    }

    /// The number of samples currently stored.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return filled
    }

    /// Clear the buffer.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        filled = 0
    }
}
