// Source-extracted lifecycle fixture. Writer, capacity, URL and VAD awaits have
// manually released gates, so every interleaving is deterministic.
import Foundation
import OSLog
import CoreMedia

@MainActor final class Gate {
    var blocked = false
    var entered = false
    var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard blocked else { return }
        entered = true
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() { blocked = false; let waiting = continuations; continuations = []; waiting.forEach { $0.resume() } }
}
@MainActor final class Settings {
    var preMarginSeconds = 0.0, minChunkDurationSeconds = 5.0
    var rmsThreshold: Float = 0.001, vadThreshold: Float = 0.5
    var chunkDurationSeconds = 30.0, silenceTimeout = 0.0
}
@MainActor final class Activity {
    enum Kind { case state, chunk, vad, error }
    func log(_ kind: Kind, _ text: String) {}
}
@MainActor final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()
    func stop() {}
}
struct Format { var sampleRate = 16_000.0 }
@MainActor final class InputNode {
    var rate = 16_000.0
    func removeTap(onBus: Int) {}
    func outputFormat(forBus: Int) -> Format { Format(sampleRate: rate) }
}
@MainActor final class AudioEngine {
    let inputNode = InputNode()
    func stop() {}
    func pause() {}
}
@MainActor final class OriginalCapacity {
    static let shared = OriginalCapacity()
    static let maximumAudioOriginalBytes: Int64 = 1_000_000
    let gate = Gate()
    var reserved = Set<UUID>()
    func reserveAudioChunk() async -> UUID? {
        await gate.wait()
        let token = UUID(); reserved.insert(token); return token
    }
    func releaseAudioChunk(_ token: UUID) { reserved.remove(token) }
}
@MainActor final class ChunkFileManager {
    let gate = Gate()
    func generateChunkURL(startedAt: Date) async -> URL {
        await gate.wait()
        return URL(fileURLWithPath: "/tmp/synthetic-\(UUID()).caf")
    }
}
@MainActor final class HubDeliveryService {
    enum Route { case audioOriginal }
    static let shared = HubDeliveryService()
    func isEnabled(_ route: Route) -> Bool { false }
    func recordGap(route: Route, reason: String) async {}
}
struct AudioStateSignal { static let lastChunkKey = "recall.synthetic.stop.lastChunk" }
struct AudioPreprocessor {
    init(sampleRate: Double = 16_000) {}
    mutating func process(_ samples: inout [Float]) {}
    static func normalizeSegment(_ samples: inout [Float]) {}
}
struct AudioConverter {
    func resample(_ samples: [Float], from rate: Double) throws -> [Float] {
        stride(from: 0, to: samples.count, by: Int(rate / 16_000)).map { samples[$0] }
    }
}
struct RMSCalculator { static func rms(of samples: [Float]) -> Float { 0.1 } }
@MainActor final class VADService {
    enum Event { case speechStart, speechEnd, none }
    struct Result { var probability: Float = 1; var event = Event.speechStart }
    let gate = Gate()
    func feed(_ samples: [Float]) async throws -> [Result] {
        await gate.wait(); return [Result(), Result(), Result()]
    }
    func reset() async {}
}
@MainActor final class ChunkWriter {
    static let finishGate = Gate()
    static var finishedSamples: [[Float]] = []
    var samples: [Float] = []
    var finishes = 0
    var hasWriteFailure = false
    init(outputURL: URL, sampleRate: Int, maximumOutputBytes: Int64?) {}
    func start() throws {}
    func appendSamples(_ values: [Float], at time: CMTime) { samples += values }
    func finish() async -> (duration: TimeInterval, fileSize: Int64) {
        finishes += 1
        await Self.finishGate.wait()
        Self.finishedSamples.append(samples)
        return (Double(samples.count) / 16_000, samples.isEmpty ? 0 : 1024)
    }
}
@MainActor final class Engine {
    enum RecordingState: String { case idle, listening, recording, paused }
    var state = RecordingState.listening
    var userStopped = false
    let settings = Settings(), activity = Activity(), audioEngine = AudioEngine()
    let logger = Logger(subsystem: "recall.synthetic", category: "lifecycle")
    let chunkFileManager = ChunkFileManager()
    let ringBuffer = RingBuffer(capacity: 144_000)
    var vadService: VADService? = VADService()
    var audioConverter: AudioConverter? = AudioConverter()
    var preprocessor = AudioPreprocessor()
    var currentWriter: ChunkWriter?
    var currentChunkURL: URL?, currentChunkStartedAt: Date?, pendingChunkStartedAt: Date?
    var audioReservationToken: UUID?
    var segmentBuffer: [Float] = [], pendingSegmentBuffer: [Float] = []
    var chunkWriteIndex = 0, vadReadIndex = 0, processingGeneration = 0
    var isFinalizingChunk = false, chunkCaptureClosed = false
    var captureHardwareSampleRate = 16_000.0
    var stopFinalizeTask: Task<Void, Never>?, processingTask: Task<Void, Never>?
    var watchdogTask: Task<Void, Never>?, resumeRetryTask: Task<Void, Never>?
    var chunkClockAtStart: Date?, chunkLastWriteAt: Date?, silenceStart: Date?
    var chunkPreRollSamples: Int?, chunkIsMerged = false
    var chunkSampleTime = CMTime.zero
    var currentRMS: Float = 0, vadProbability: Float = 0
    var noiseFloorRMS: Float = 0.002
    let noiseFloorAlpha: Float = 0.05, noiseFloorCap: Float = 0.01, noiseFloorMultiplier: Float = 1.2
    var chunkRMSSum: Float = 0, chunkVADSum: Float = 0, chunkVADPeak: Float = 0
    var chunkRMSCount = 0, chunkVADCount = 0, chunksRecorded = 0
    var voiceIslandCurrentRun = 0, voiceIslandMaxRun = 0, voiceIslandFrameCount = 0
    var voiceIslandTotalFrames = 0, voiceIslandGapCount = 0, consecutiveVoiceFrames = 0
    let voiceIslandGapFillMax = 3, requiredConsecutiveFrames = 3, targetSampleRate = 16_000
    let pendingTimeout = 120.0
    var savedDurations: [Double] = []
    func saveChunkRecord(url: URL, startedAt: Date, duration: TimeInterval, fileSize: Int64,
        avgRMS: Float, vadAvgProb: Float, noiseFloorRMS: Float, maxContinuousVoiceMs: Int = 0,
        voiceFrameRatio: Float = 0, maxVadProb: Float = 0, captureClockAtStart: Date? = nil,
        capturePreRollSamples: Int? = nil, captureLastWriteAt: Date? = nil) async {
        savedDurations.append(duration)
    }
    func seed(_ count: Int) {
        currentWriter = ChunkWriter(outputURL: URL(fileURLWithPath: "/tmp/synthetic.caf"), sampleRate: 16_000, maximumOutputBytes: nil)
        currentChunkURL = URL(fileURLWithPath: "/tmp/synthetic.caf")
        currentChunkStartedAt = Date(); segmentBuffer = Array(repeating: 0.1, count: count)
        state = .recording
    }
    // ENGINE_METHODS
}

@main struct Run {
    @MainActor static func until(_ predicate: () -> Bool) async {
        for _ in 0..<10_000 { if predicate() { return }; await Task.yield() }
        fatalError("Gate never entered")
    }
    @MainActor static func main() async {
        var failed = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)"); fflush(stdout); if !value { failed += 1 }
        }
        defer { UserDefaults.standard.removeObject(forKey: AudioStateSignal.lastChunkKey) }
        for stage in ["admission", "URL"] {
            let engine = Engine()
            let gate = stage == "admission" ? OriginalCapacity.shared.gate : engine.chunkFileManager.gate
            gate.blocked = true; gate.entered = false
            let work = Task { await engine.handleVoiceDetected() }
            engine.processingTask = work
            await until { gate.entered }
            engine.stop(intentional: true)
            gate.release()
            await work.value; await engine.stopFinalizeTask?.value
            check(engine.state == .idle && engine.currentWriter == nil && OriginalCapacity.shared.reserved.isEmpty,
                  "stop while awaiting \(stage): idle, no writer, reservation released")
        }
        let vad = Engine(); vad.vadService!.gate.blocked = true
        vad.ringBuffer.write(Array(repeating: 0.1, count: 1600))
        let oldVAD = Task { await vad.processCurrentAudio() } // Generation guard alone, without Task cancellation.
        await until { vad.vadService!.gate.entered }
        vad.stop(intentional: true)
        vad.state = .listening // Immediate restart state alone must not validate the old continuation.
        vad.vadService!.gate.release()
        await oldVAD.value; await vad.stopFinalizeTask?.value
        check(vad.currentWriter == nil && vad.consecutiveVoiceFrames == 0,
              "stale VAD after restart cannot install writer or update detector state")

        let tail = Engine(); tail.seed(160_000)
        tail.captureHardwareSampleRate = 48_000
        tail.audioEngine.inputNode.rate = 48_000
        tail.ringBuffer.write(Array(repeating: 0.2, count: 4800))
        let writer = tail.currentWriter!
        tail.stop(intentional: true)
        // Replace rate/ring as restart does before the queued finalizer runs.
        tail.captureHardwareSampleRate = 16_000; tail.audioEngine.inputNode.rate = 16_000
        tail.ringBuffer.reset(); tail.ringBuffer.write(Array(repeating: 0.9, count: 3200))
        await tail.stopFinalizeTask?.value
        check(writer.finishes == 1 && writer.samples.count == 161_600 && writer.samples.suffix(1600).allSatisfy { $0 == 0.2 },
              "10s stop drains 4800 accepted 48kHz tail samples exactly once; excludes restart audio")
        print("tail encoded sample count=\(writer.samples.count), expected=161600")

        let finish = Engine(); finish.seed(160_000)
        let finishingWriter = finish.currentWriter!
        ChunkWriter.finishGate.blocked = true; ChunkWriter.finishGate.entered = false
        let processing = Task { await finish.handleSilence() }; finish.processingTask = processing
        await until { ChunkWriter.finishGate.entered }
        finish.stop(intentional: true); finish.stop(intentional: true)
        finish.state = .recording // A resumed generation must keep its state.
        let restarting = Task { await finish.startNewChunk() }
        for _ in 0..<20 { await Task.yield() }
        check(finish.currentWriter === finishingWriter && finishingWriter.finishes == 1,
              "restart admission waits for old writer.finish")
        ChunkWriter.finishGate.release()
        await processing.value; await finish.stopFinalizeTask?.value; await restarting.value
        check(finishingWriter.finishes == 1 && finish.savedDurations.count == 1 && finish.currentWriter != nil && finish.currentWriter !== finishingWriter && finish.state == .recording,
              "stop during writer.finish + repeated stop finalize once; new writer survives old cleanup")
        finish.stop(intentional: true); await finish.stopFinalizeTask?.value

        for count in [0, 4000, 32_000, 64_000] {
            let short = Engine(); short.seed(count); short.stop(intentional: true)
            await short.stopFinalizeTask?.value
            check(short.currentWriter == nil && short.pendingSegmentBuffer.isEmpty && short.savedDurations.count == (count >= 48_000 ? 1 : 0),
                  "explicit empty/short policy: \(count) samples")
        }
        let queuedLoop = Engine()
        queuedLoop.startProcessingLoop()
        queuedLoop.stop(intentional: true)
        await queuedLoop.stopFinalizeTask?.value
        check(queuedLoop.state == .idle, "stop before processing task starts cannot await itself")
        let interruption = Engine(); interruption.seed(160_000)
        let interruptedWriter = interruption.currentWriter!
        interruption.ringBuffer.write(Array(repeating: 0.2, count: 1600))
        interruption.handleInterruptionBegan()
        await interruption.stopFinalizeTask?.value
        check(interruption.state == .paused && interruptedWriter.samples.count == 161_600 && interruptedWriter.finishes == 1 && interruption.ringBuffer.count == 0,
              "interruption preserves tail and finalizes once")
        print("failures=\(failed)")
        if failed > 0 { exit(1) }
    }
}
