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

    func testPreMarginAndContinuationJoinWithoutRepeatOrGap() {
        // A chunk takes its pre-margin and then everything that follows. Whatever arrives
        // between ticks must appear exactly once, in order, however long the tick is.
        let buffer = RingBuffer(capacity: 1_000)
        buffer.write((0..<300).map(Float.init))

        let (preMargin, endIndex) = buffer.readLast(100)
        XCTAssertEqual(preMargin, (200..<300).map(Float.init))

        buffer.write((300..<340).map(Float.init))
        let (first, next) = buffer.read(after: endIndex)
        buffer.write((340..<500).map(Float.init))
        let (second, _) = buffer.read(after: next)

        XCTAssertEqual(preMargin + first + second, (200..<500).map(Float.init))
    }

    func testASlowReaderIsToldHowMuchWasLost() {
        let buffer = RingBuffer(capacity: 100)
        buffer.write((0..<250).map(Float.init))

        let result = buffer.readAfter(0)

        XCTAssertEqual(result.skipped, 150)
        XCTAssertEqual(result.samples.first, 150)
        XCTAssertEqual(result.nextIndex, 250)
        XCTAssertEqual(buffer.readAfter(result.nextIndex).skipped, 0)
    }

    func testSamplesAndNextIndexAlwaysDescribeTheSameStretch() {
        // Whatever the tap writes, samples returned == nextIndex - start, with no gap in
        // the numbering: the sequence read piecewise equals the sequence written.
        let buffer = RingBuffer(capacity: 1_000)
        var written = 0
        var cursor = 0
        var collected: [Float] = []
        for step in 1...50 {
            buffer.write((written..<(written + step * 3)).map(Float.init))
            written += step * 3
            let r = buffer.readAfter(cursor)
            XCTAssertEqual(r.skipped, 0)
            collected += r.samples
            cursor = r.nextIndex
        }
        XCTAssertEqual(collected, (0..<written).map(Float.init))
    }
}
