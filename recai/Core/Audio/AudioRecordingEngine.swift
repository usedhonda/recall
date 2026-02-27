import AVFoundation
import FluidAudio
import Observation
import OSLog
import SwiftData

/// Central orchestrator: AVAudioEngine tap -> RingBuffer -> RMS -> VAD -> ChunkWriter.
@Observable
@MainActor
final class AudioRecordingEngine {

    // MARK: - Public State

    enum RecordingState: String {
        case idle
        case listening
        case recording
        case paused
    }

    private(set) var state: RecordingState = .idle
    private(set) var currentRMS: Float = 0
    private(set) var vadProbability: Float = 0
    private(set) var chunksRecorded: Int = 0

    var isRecording: Bool { state == .recording }

    var currentChunkDuration: TimeInterval {
        guard let start = currentChunkStartedAt else { return 0 }
        return Date().timeIntervalSince(start)
    }

    // MARK: - Dependencies

    private let settings = AppSettings.shared
    private let sessionManager = AudioSessionManager.shared
    private let chunkFileManager = ChunkFileManager.shared

    // MARK: - Audio Pipeline

    private let audioEngine = AVAudioEngine()
    private let ringBuffer = RingBuffer()
    private var vadService: VADService?
    private var audioConverter: AudioConverter?

    // MARK: - Chunk State

    private var currentWriter: ChunkWriter?
    private var currentChunkURL: URL?
    private var currentChunkStartedAt: Date?
    private var chunkSampleTime: CMTime = .zero

    // MARK: - VAD State

    private var silenceStart: Date?
    private var processingTask: Task<Void, Never>?

    // MARK: - SwiftData

    private var modelContainer: ModelContainer?

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.example.recai", category: "RecordingEngine")

    // MARK: - Constants

    private let targetSampleRate: Int = 16_000
    private let tapBufferSize: AVAudioFrameCount = 4096

    // MARK: - Init

    init() {}

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    // MARK: - Start / Stop

    func start() async throws {
        guard state == .idle || state == .paused else {
            logger.warning("Cannot start from state: \(self.state.rawValue)")
            return
        }

        // Configure audio session
        try sessionManager.configure()

        // Setup interruption callbacks
        sessionManager.onInterruptionBegan = { [weak self] in
            Task { @MainActor in
                self?.handleInterruptionBegan()
            }
        }
        sessionManager.onInterruptionEnded = { [weak self] shouldResume in
            Task { @MainActor in
                self?.handleInterruptionEnded(shouldResume: shouldResume)
            }
        }

        // Initialize VAD
        if vadService == nil {
            vadService = try await VADService()
        }

        // Initialize audio converter for resampling
        if audioConverter == nil {
            audioConverter = AudioConverter()
        }

        // Reset ring buffer
        ringBuffer.reset()

        // Setup audio engine tap
        let inputNode = audioEngine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        let hwSampleRate = hwFormat.sampleRate

        logger.info("Hardware sample rate: \(hwSampleRate) Hz, channels: \(hwFormat.channelCount)")

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hwFormat) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer, hardwareSampleRate: hwSampleRate)
        }

        audioEngine.prepare()
        try audioEngine.start()

        state = .listening
        logger.info("Recording engine started, listening for voice")

        // Start the processing loop
        startProcessingLoop()
    }

    func stop() {
        processingTask?.cancel()
        processingTask = nil

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Finalize any in-progress chunk
        if currentWriter != nil {
            Task { @MainActor in
                await self.finalizeCurrentChunk()
            }
        }

        state = .idle
        currentRMS = 0
        vadProbability = 0
        silenceStart = nil

        logger.info("Recording engine stopped")
    }

    // MARK: - Audio Buffer Handling (called from audio thread)

    /// Receives raw audio from the tap callback.
    /// Writes to ring buffer synchronously (lock-based, realtime-safe).
    private nonisolated func handleAudioBuffer(_ buffer: AVAudioPCMBuffer, hardwareSampleRate: Double) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))

        // Always write to ring buffer at hardware rate for pre-margin retrieval
        ringBuffer.write(samples)
    }

    // MARK: - Processing Loop

    private func startProcessingLoop() {
        processingTask = Task { [weak self] in
            guard let self else { return }
            // Process in ~100ms intervals
            let intervalNs: UInt64 = 100_000_000

            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNs)
                } catch {
                    break
                }
                await self.processCurrentAudio()
            }
        }
    }

    private func processCurrentAudio() async {
        guard state == .listening || state == .recording else { return }

        // Read recent samples from ring buffer for analysis
        let analysisWindow: TimeInterval = 0.1 // 100ms
        let hwRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        let hwSampleCount = Int(analysisWindow * hwRate)
        let rawSamples = ringBuffer.read(lastSamples: hwSampleCount)
        guard !rawSamples.isEmpty else { return }

        // Resample to 16kHz for RMS + VAD
        let samples16k: [Float]
        let hwSampleRate = hwRate
        if Int(hwSampleRate) != targetSampleRate, let converter = audioConverter {
            do {
                samples16k = try converter.resample(rawSamples, from: hwSampleRate)
            } catch {
                logger.error("Resample failed: \(error.localizedDescription)")
                return
            }
        } else {
            samples16k = rawSamples
        }

        // Stage 1: RMS power gate
        let rms = RMSCalculator.rms(of: samples16k)
        currentRMS = rms

        if rms < settings.rmsThreshold {
            // Below RMS threshold — treat as silence
            await handleSilence()
            return
        }

        // Stage 2: Silero VAD
        guard let vadService else { return }
        do {
            let result = try await vadService.processChunk(samples16k)
            vadProbability = result.probability

            if result.probability >= settings.vadThreshold || result.event == .speechStart {
                await handleVoiceDetected()
            } else {
                await handleSilence()
            }
        } catch {
            logger.error("VAD processing error: \(error.localizedDescription)")
        }
    }

    // MARK: - State Transitions

    private func handleVoiceDetected() async {
        silenceStart = nil

        switch state {
        case .listening:
            // Transition: listening -> recording
            logger.info("Voice detected, starting recording")
            await startNewChunk()
            state = .recording

        case .recording:
            // Continue recording; write current audio
            await writeCurrentAudioToChunk()

            // Check chunk duration limit
            if let startedAt = currentChunkStartedAt,
               Date().timeIntervalSince(startedAt) >= settings.chunkDurationSeconds {
                logger.info("Chunk duration exceeded, splitting")
                await splitChunk()
            }

        default:
            break
        }
    }

    private func handleSilence() async {
        guard state == .recording else { return }

        if silenceStart == nil {
            silenceStart = Date()
        }

        // Still write audio during post-margin
        await writeCurrentAudioToChunk()

        // Check silence timeout
        if let silenceStart, Date().timeIntervalSince(silenceStart) >= settings.silenceTimeout {
            logger.info("Silence timeout reached, stopping recording")
            await finalizeCurrentChunk()
            state = .listening
            self.silenceStart = nil
            vadProbability = 0
        }
    }

    // MARK: - Chunk Lifecycle

    private func startNewChunk() async {
        let now = Date()
        let url = await chunkFileManager.generateChunkURL(startedAt: now)

        let writer = ChunkWriter(outputURL: url, sampleRate: targetSampleRate)
        do {
            try writer.start()
        } catch {
            logger.error("Failed to start chunk writer: \(error.localizedDescription)")
            return
        }

        currentWriter = writer
        currentChunkURL = url
        currentChunkStartedAt = now
        chunkSampleTime = .zero

        // Write pre-margin from ring buffer
        let hwRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        let preMarginSamples = ringBuffer.read(lastSeconds: settings.preMarginSeconds, sampleRate: Int(hwRate))
        if !preMarginSamples.isEmpty {
            let samples16k: [Float]
            if Int(hwRate) != targetSampleRate, let converter = audioConverter {
                samples16k = (try? converter.resample(preMarginSamples, from: hwRate)) ?? preMarginSamples
            } else {
                samples16k = preMarginSamples
            }
            writer.appendSamples(samples16k, at: chunkSampleTime)
            let frameDuration = CMTime(value: CMTimeValue(samples16k.count), timescale: CMTimeScale(targetSampleRate))
            chunkSampleTime = CMTimeAdd(chunkSampleTime, frameDuration)
        }

        logger.info("New chunk started: \(url.lastPathComponent)")
    }

    private func writeCurrentAudioToChunk() async {
        guard let writer = currentWriter else { return }

        let hwRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        let analysisWindow: TimeInterval = 0.1
        let hwSampleCount = Int(analysisWindow * hwRate)
        let rawSamples = ringBuffer.read(lastSamples: hwSampleCount)
        guard !rawSamples.isEmpty else { return }

        let samples16k: [Float]
        if Int(hwRate) != targetSampleRate, let converter = audioConverter {
            samples16k = (try? converter.resample(rawSamples, from: hwRate)) ?? rawSamples
        } else {
            samples16k = rawSamples
        }

        writer.appendSamples(samples16k, at: chunkSampleTime)
        let frameDuration = CMTime(value: CMTimeValue(samples16k.count), timescale: CMTimeScale(targetSampleRate))
        chunkSampleTime = CMTimeAdd(chunkSampleTime, frameDuration)
    }

    private func finalizeCurrentChunk() async {
        guard let writer = currentWriter, let url = currentChunkURL, let startedAt = currentChunkStartedAt else {
            return
        }

        let result = await writer.finish()
        currentWriter = nil
        currentChunkURL = nil
        currentChunkStartedAt = nil
        chunkSampleTime = .zero

        // Skip empty or extremely short chunks
        guard result.duration > 0.5, result.fileSize > 0 else {
            logger.info("Discarding trivially short chunk: \(result.duration, format: .fixed(precision: 1))s")
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Create SwiftData record
        await saveChunkRecord(url: url, startedAt: startedAt, duration: result.duration, fileSize: result.fileSize)
        chunksRecorded += 1

        logger.info("Chunk finalized: \(url.lastPathComponent), duration: \(result.duration, format: .fixed(precision: 1))s")
    }

    private func splitChunk() async {
        await finalizeCurrentChunk()
        await startNewChunk()
    }

    // MARK: - SwiftData Persistence

    private func saveChunkRecord(url: URL, startedAt: Date, duration: TimeInterval, fileSize: Int64) async {
        guard let modelContainer else {
            logger.error("ModelContainer not set, cannot save chunk record")
            return
        }

        let context = ModelContext(modelContainer)
        let chunk = AudioChunk(
            filePath: url.path,
            fileName: url.lastPathComponent,
            startedAt: startedAt,
            duration: duration,
            fileSize: fileSize
        )
        context.insert(chunk)

        do {
            try context.save()
            logger.info("Saved AudioChunk record: \(chunk.fileName)")
        } catch {
            logger.error("Failed to save AudioChunk: \(error.localizedDescription)")
        }
    }

    // MARK: - Interruption Handling

    private func handleInterruptionBegan() {
        guard state == .listening || state == .recording else { return }
        logger.info("Handling interruption began, pausing")

        if state == .recording {
            Task {
                await finalizeCurrentChunk()
            }
        }

        audioEngine.pause()
        state = .paused
    }

    private func handleInterruptionEnded(shouldResume: Bool) {
        guard state == .paused, shouldResume else {
            logger.info("Interruption ended but not resuming (shouldResume: \(shouldResume))")
            return
        }

        logger.info("Resuming after interruption")
        do {
            try audioEngine.start()
            state = .listening
            startProcessingLoop()
        } catch {
            logger.error("Failed to resume audio engine: \(error.localizedDescription)")
            state = .idle
        }
    }
}
