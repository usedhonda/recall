import XCTest
@testable import recall

/// The speech detector carries state from one window to the next, so it has to hear the
/// microphone exactly once and in order. Repeating audio was what made its answers
/// meaningless (measured 2026-09-13); skipping audio would cut sentences in half. This
/// pins the read that keeps the sequence honest.
final class RingBufferStreamTests: XCTestCase {
    func testEachSampleIsHandedOverExactlyOnce() {
        let buffer = RingBuffer(capacity: 1000)
        var index = 0
        var heard: [Float] = []

        for batch in 0..<10 {
            buffer.write((0..<37).map { Float(batch * 37 + $0) })
            let (samples, next) = buffer.read(after: index)
            index = next
            heard.append(contentsOf: samples)
        }

        XCTAssertEqual(heard, (0..<370).map(Float.init))
    }

    func testNothingNewMeansNothingRead() {
        let buffer = RingBuffer(capacity: 100)
        buffer.write([1, 2, 3])
        let (_, index) = buffer.read(after: 0)

        let (again, sameIndex) = buffer.read(after: index)

        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(sameIndex, index)
    }

    func testAReaderThatFallsBehindGetsWhatIsLeft() {
        // The ring holds 100 samples; 250 were written while nobody was listening. The
        // oldest 150 are gone — the reader takes the rest rather than stalling.
        let buffer = RingBuffer(capacity: 100)
        buffer.write((0..<250).map(Float.init))

        let (samples, next) = buffer.read(after: 0)

        XCTAssertEqual(samples.count, 100)
        XCTAssertEqual(samples.first, 150)
        XCTAssertEqual(next, 250)
    }
}
