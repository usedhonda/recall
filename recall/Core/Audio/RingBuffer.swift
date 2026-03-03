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

    /// Initialize with capacity in samples.
    /// Default: 3 seconds at 16kHz = 48000 samples.
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

    /// Read the last N seconds of samples from the buffer.
    func read(lastSeconds seconds: TimeInterval, sampleRate: Int = 16_000) -> [Float] {
        let count = min(Int(seconds * Double(sampleRate)), filled)
        return read(lastSamples: count)
    }

    /// Read the last N samples from the buffer.
    func read(lastSamples count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

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
