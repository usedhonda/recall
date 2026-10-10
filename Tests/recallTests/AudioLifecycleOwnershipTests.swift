import XCTest
@testable import recall

@MainActor
final class AudioLifecycleOwnershipTests: XCTestCase {
    func testStopInvalidatesOldGenerationBeforeSuspension() {
        let ownership = AudioLifecycleOwnership(queue: AudioFinalizationQueue())
        let old = ownership.generation.token
        _ = ownership.beginStop()
        XCTAssertFalse(ownership.accepts(old))
    }

    func testDetachedOwnerRetainsResourceAndJoinsRepeatedFinish() async {
        let gate = Gate()
        var finishes = 0
        var releases = 0
        var resource: Resource? = Resource()
        weak var retained = resource
        let owner = AudioFinalizationOwner(resource!) { releases += 1 }
        resource = nil
        let first = Task { await owner.finish { _ in finishes += 1; await gate.wait() } }
        await gate.waitForEntry()
        let second = Task { await owner.finish { _ in XCTFail("second finish must join") } }
        XCTAssertNotNil(retained)
        XCTAssertEqual(releases, 0)
        gate.open()
        await first.value
        await second.value
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(releases, 1)
    }

    func testAdmissionReturningAfterStopReleasesWithoutPublishing() async {
        let lifecycle = AudioLifecycleOwnership(queue: AudioFinalizationQueue())
        let gate = Gate()
        let generation = lifecycle.generation.token
        var releases = 0
        let admission = Task {
            await lifecycle.acquire(generation: generation, reserve: {
                await gate.wait(); return 42
            }, release: { _ in releases += 1 })
        }
        await gate.waitForEntry()
        _ = lifecycle.beginStop()
        gate.open()
        let result = await admission.value
        XCTAssertNil(result)
        XCTAssertEqual(releases, 1)
        let replacement = await lifecycle.acquire(generation: lifecycle.generation.token,
            reserve: { 43 }, release: { _ in XCTFail("new resource must remain owned") })
        XCTAssertEqual(replacement, 43)
    }

    func testAcceptedTailIsDrainedOnceAndOldTapCannotWriteAfterRestart() {
        let ring = RingBuffer(capacity: 144_000)
        let admission = AudioTapAdmission()
        let old = admission.open()
        var index = ring.totalWritten
        var captured: [Float] = []
        for _ in 0..<10 {
            admission.write(Array(repeating: 1, count: 48_000), token: old, to: ring)
            let read = ring.readAfter(index)
            captured += read.samples; index = read.nextIndex
        }
        admission.write(Array(repeating: 2, count: 12_000), token: old, to: ring)
        admission.close()
        admission.write([99], token: old, to: ring)
        let tail = ring.readAfter(index)
        captured += tail.samples
        XCTAssertEqual(captured.count, 492_000) // 10.25 s at the old 48 kHz rate.
        XCTAssertEqual(tail.samples, Array(repeating: 2, count: 12_000))
        XCTAssertTrue(ring.readAfter(tail.nextIndex).samples.isEmpty)
        ring.reset()
        let replacement = admission.open()
        admission.write([99], token: old, to: ring)
        admission.write([3], token: replacement, to: ring)
        XCTAssertEqual(ring.readLast(10).samples, [3])
    }

    func testProcessingWaitDoesNotJoinStopThatWaitsForProcessing() async {
        let queue = AudioFinalizationQueue()
        let gate = Gate()
        queue.enqueue { await gate.wait() }
        await gate.waitForEntry()
        let processing = Task { await queue.waitExisting() }
        await Task.yield()
        let stop = queue.enqueue { await processing.value }
        gate.open()
        await stop.value
    }

    func testReplacementEngineWaitsForPriorFinalization() async {
        let queue = AudioFinalizationQueue()
        let firstGate = Gate()
        var events: [String] = []
        let first = queue.enqueue {
            events.append("old-start")
            await firstGate.wait()
            events.append("old-finish")
        }
        let second = queue.enqueue { events.append("new") }
        await firstGate.waitForEntry()
        XCTAssertEqual(events, ["old-start"])
        firstGate.open()
        await first.value
        await second.value
        XCTAssertEqual(events, ["old-start", "old-finish", "new"])
    }
}

private final class Resource {}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entry: CheckedContinuation<Void, Never>?
    private var entered = false
    private var opened = false

    func wait() async {
        entered = true
        entry?.resume(); entry = nil
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }

    func open() {
        opened = true
        continuation?.resume(); continuation = nil
    }
}
