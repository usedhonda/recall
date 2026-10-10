import AVFoundation
import FluidAudio
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

    func testCancelledResumeAfterBarrierDoesNotRestart() async {
        let queue = AudioFinalizationQueue()
        let generation = AudioCaptureGeneration()
        let barrier = Gate()
        let entered = Gate()
        queue.enqueue { await barrier.wait() }
        await barrier.waitForEntry()
        var restarts = 0
        let request = Task {
            entered.open()
            await queue.resumeWhenReady(generation: generation, token: generation.token,
                stopped: { false }, needsResume: { true }, resume: { restarts += 1 })
        }
        await entered.wait()
        request.cancel()
        barrier.open()
        await request.value
        XCTAssertEqual(restarts, 0)
    }

    func testInvalidatedResumeAfterBarrierDoesNotRestart() async {
        let queue = AudioFinalizationQueue()
        let generation = AudioCaptureGeneration()
        let token = generation.token
        let barrier = Gate()
        let entered = Gate()
        queue.enqueue { await barrier.wait() }
        await barrier.waitForEntry()
        var restarts = 0
        let request = Task {
            entered.open()
            await queue.resumeWhenReady(generation: generation, token: token,
                stopped: { false }, needsResume: { true }, resume: { restarts += 1 })
        }
        await entered.wait()
        generation.invalidate()
        barrier.open()
        await request.value
        XCTAssertEqual(restarts, 0)
    }

    func testStoppedMicOperationCannotContinueAfterHFPWait() async {
        // Same production admission seam used by RecordingViewModel after HFP awaits.
        let operations = AudioCaptureGeneration()
        let operation = operations.token
        let hfpWait = Gate()
        var stopped = false
        var replacements = 0
        let request = Task {
            await hfpWait.wait()
            guard operations.acceptsActive(operation, stopped: stopped) else { return }
            replacements += 1
        }
        await hfpWait.waitForEntry()
        operations.invalidate()
        stopped = true
        // A later Start clears stop intent, but cannot grant an old HFP operation ownership.
        stopped = false
        hfpWait.open()
        await request.value
        XCTAssertEqual(replacements, 0)
        XCTAssertTrue(operations.acceptsActive(operations.token, stopped: false))
        XCTAssertFalse(operations.acceptsActive(operations.token, stopped: true))
    }

    func testTwoResumeRequestsAfterSharedBarrierResetAndInstallOnlyOnce() async {
        let queue = AudioFinalizationQueue()
        let generation = AudioCaptureGeneration()
        let token = generation.token
        let barrier = Gate()
        let firstEntered = Gate()
        let secondEntered = Gate()
        queue.enqueue { await barrier.wait() }
        await barrier.waitForEntry()
        var paused = true
        var resets = 0
        var installs = 0
        let resume = {
            resets += 1
            installs += 1
            paused = false
        }
        let first = Task {
            firstEntered.open()
            await queue.resumeWhenReady(generation: generation, token: token,
                stopped: { false }, needsResume: { paused }, resume: resume)
        }
        await firstEntered.wait()
        let second = Task {
            secondEntered.open()
            await queue.resumeWhenReady(generation: generation, token: token,
                stopped: { false }, needsResume: { paused }, resume: resume)
        }
        await secondEntered.wait()
        XCTAssertEqual(installs, 0)
        barrier.open()
        await first.value
        await second.value
        XCTAssertEqual(resets, 1)
        XCTAssertEqual(installs, 1)
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

    func testAcceptedTailProducesOneOriginalWithOldRate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.caf")
        let ring = RingBuffer(capacity: 144_000)
        let admission = AudioTapAdmission()
        let oldTap = admission.open()
        let oldRate = 48_000.0
        var cursor = ring.totalWritten
        var samples: [Float] = []
        for _ in 0..<10 {
            admission.write(Array(repeating: 0.02, count: 48_000), token: oldTap, to: ring)
            let read = ring.readAfter(cursor); cursor = read.nextIndex; samples += read.samples
        }
        admission.write(Array(repeating: 0.03, count: 12_000), token: oldTap, to: ring)
        admission.close()
        samples += ring.readAfter(cursor).samples
        let converted = try AudioConverter().resample(samples, from: oldRate)
        XCTAssertEqual(Double(converted.count), 164_000, accuracy: 2)
        let writer = ChunkWriter(outputURL: url, sampleRate: 16_000, maximumOutputBytes: 1_000_000)
        try writer.start()
        let owner = AudioFinalizationOwner((writer, converted)) {}
        var finishedDuration = 0.0
        await owner.finish { snapshot in
            snapshot.0.appendSamples(snapshot.1, at: .zero)
            finishedDuration = await snapshot.0.finish().duration
        }
        await owner.finish { _ in XCTFail("the same original must not be finished again") }
        XCTAssertEqual(finishedDuration, 10.25, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
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
