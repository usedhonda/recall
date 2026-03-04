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
    private var preprocessor = AudioPreprocessor()

    // MARK: - Chunk State

    private var currentWriter: ChunkWriter?
    private var currentChunkURL: URL?
    private var currentChunkStartedAt: Date?
    private var chunkSampleTime: CMTime = .zero
    private var segmentBuffer: [Float] = []

    // MARK: - Pending Buffer (short chunk deferral)

    private var pendingSegmentBuffer: [Float] = []
    private var pendingChunkStartedAt: Date?
    private let pendingTimeout: TimeInterval = 120.0

    // MARK: - VAD State

    private var silenceStart: Date?
    private var processingTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    // MARK: - Per-Chunk Quality Metrics

    private var chunkRMSSum: Float = 0
    private var chunkRMSCount: Int = 0
    private var chunkVADSum: Float = 0
    private var chunkVADCount: Int = 0

    // MARK: - Adaptive Noise Floor

    private var noiseFloorRMS: Float = 0.002
    private let noiseFloorAlpha: Float = 0.05 // smoothing factor
    private let noiseFloorMultiplier: Float = 1.5 // threshold = floor * multiplier (Step 1: pocket/distance capture)

    // MARK: - SwiftData

    private var modelContainer: ModelContainer?

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.example.recall", category: "RecordingEngine")
    private let activity = ActivityLogger.shared

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

        // Setup route change callback
        sessionManager.onRouteChanged = { [weak self] reason in
            Task { @MainActor in
                self?.handleRouteChange(reason: reason)
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

        // Remove any existing tap to prevent double-install crash (SIGABRT)
        // Safe no-op if no tap is installed
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hwFormat) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer, hardwareSampleRate: hwSampleRate)
        }

        audioEngine.prepare()
        try audioEngine.start()

        state = .listening
        logger.info("Recording engine started, listening for voice")
        activity.log(.state, "Engine started — Listening (\(Int(hwSampleRate))Hz, buf=\(tapBufferSize))")

        // Start silent playback + NowPlaying to keep iOS from killing our session
        BackgroundKeepAlive.shared.start()

        // Start the processing loop
        startProcessingLoop()

        // Start watchdog timer (safety net for silent failures)
        startWatchdog()
    }

    func stop() {
        watchdogTask?.cancel()
        watchdogTask = nil
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

        // Stop keep-alive silent playback
        BackgroundKeepAlive.shared.stop()

        state = .idle
        currentRMS = 0
        vadProbability = 0
        silenceStart = nil
        segmentBuffer = []
        pendingSegmentBuffer = []
        pendingChunkStartedAt = nil

        logger.info("Recording engine stopped")
        activity.log(.state, "Engine stopped")
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

    /// Watchdog is immortal — never cancelled except by stop().
    /// It survives restartEngine() failures and keeps retrying forever.
    private func startWatchdog() {
        guard watchdogTask == nil else { return } // don't double-start
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10s
                guard let self else { return }

                switch self.state {
                case .listening, .recording:
                    // Check audio engine is still running
                    if !self.audioEngine.isRunning {
                        self.logger.warning("Watchdog: audioEngine not running, restarting")
                        self.activity.log(.error, "Watchdog: audioEngine stopped — restarting")
                        self.restartEngine()
                        continue
                    }

                    // Check BackgroundKeepAlive is still playing
                    if !BackgroundKeepAlive.shared.isPlaying {
                        self.logger.warning("Watchdog: BackgroundKeepAlive not playing, resuming")
                        self.activity.log(.error, "Watchdog: KeepAlive stopped — resuming")
                        BackgroundKeepAlive.shared.resumePlayback()
                    }

                    // Check ring buffer is receiving data
                    let silentDuration = Date().timeIntervalSince(self.ringBuffer.lastWriteTime)
                    if silentDuration > 10 {
                        self.logger.warning("Watchdog: no audio data for \(Int(silentDuration))s, restarting engine")
                        self.activity.log(.error, "Watchdog triggered — no data for \(Int(silentDuration))s, restarting")
                        self.restartEngine()
                    }

                case .idle:
                    // Engine died (e.g. resume failed) — try full restart
                    self.logger.warning("Watchdog: engine idle, attempting full restart")
                    self.activity.log(.error, "Watchdog: engine idle — attempting restart")
                    self.restartEngine()

                case .paused:
                    // Stuck in paused (interruption never ended?) — force resume
                    self.logger.warning("Watchdog: engine stuck in paused, force-resuming")
                    self.activity.log(.error, "Watchdog: stuck paused — force-resuming")
                    self.resumeAfterInterruption()
                }
            }
        }
    }

    private func startProcessingLoop() {
        // Cancel any existing processing task to prevent double-running
        processingTask?.cancel()
        processingTask = nil

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

        // Flush pending buffer if it has been held too long (send short chunk rather than lose it)
        if state == .listening, !pendingSegmentBuffer.isEmpty, let pendingStart = pendingChunkStartedAt {
            if Date().timeIntervalSince(pendingStart) >= pendingTimeout {
                let pendingDuration = Double(pendingSegmentBuffer.count) / Double(targetSampleRate)
                logger.info("Pending timeout — force-finalizing held chunk (\(pendingDuration, format: .fixed(precision: 1))s)")
                activity.log(.chunk, "Pending timeout — force-finalize \(String(format: "%.1f", pendingDuration))s")
                await forceFinalizePendingBuffer()
            }
        }

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

        // Stage 1: RMS power gate (adaptive threshold)
        let rms = RMSCalculator.rms(of: samples16k)
        currentRMS = rms

        // Update noise floor estimate during listening (silence)
        let effectiveThreshold: Float
        if state == .listening {
            noiseFloorRMS = noiseFloorRMS * (1 - noiseFloorAlpha) + rms * noiseFloorAlpha
            effectiveThreshold = max(noiseFloorRMS * noiseFloorMultiplier, settings.rmsThreshold)
        } else {
            effectiveThreshold = max(noiseFloorRMS * noiseFloorMultiplier, settings.rmsThreshold)
        }

        // Accumulate RMS during recording for quality metadata
        if state == .recording {
            chunkRMSSum += rms
            chunkRMSCount += 1
        }

        if rms < effectiveThreshold {
            await handleSilence()
            return
        }

        // Stage 2: Silero VAD
        guard let vadService else { return }
        do {
            let result = try await vadService.processChunk(samples16k)
            vadProbability = result.probability

            // Accumulate VAD probability during recording
            if state == .recording {
                chunkVADSum += result.probability
                chunkVADCount += 1
            }

            if result.probability >= settings.vadThreshold || result.event == .speechStart {
                await handleVoiceDetected()
            } else {
                await handleSilence()
            }
        } catch {
            logger.error("VAD processing error: \(error.localizedDescription)")
            activity.log(.error, "VAD error: \(error.localizedDescription)")
        }
    }

    // MARK: - State Transitions

    private func handleVoiceDetected() async {
        silenceStart = nil

        switch state {
        case .listening:
            // Transition: listening -> recording
            logger.info("Voice detected, starting recording")
            activity.log(.vad, "Voice detected — RMS=\(String(format: "%.3f", currentRMS)) VAD=\(String(format: "%.2f", vadProbability))")
            await startNewChunk()
            state = .recording
            activity.log(.state, "Recording started")

        case .recording:
            // Continue recording; write current audio
            await writeCurrentAudioToChunk()

            // Check chunk duration limit
            if let startedAt = currentChunkStartedAt,
               Date().timeIntervalSince(startedAt) >= settings.chunkDurationSeconds {
                logger.info("Chunk duration exceeded, splitting")
                activity.log(.chunk, "Chunk duration limit — splitting")
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
            activity.log(.vad, "Silence \(String(format: "%.1f", settings.silenceTimeout))s — finalizing chunk")
            await finalizeCurrentChunk()
            state = .listening
            self.silenceStart = nil
            vadProbability = 0
            activity.log(.state, "Back to Listening")
        }
    }

    // MARK: - Chunk Lifecycle

    private func startNewChunk() async {
        // Use pending chunk's timestamp if available (preserves original timing for voicelog merge)
        let effectiveStart = pendingChunkStartedAt ?? Date()
        let url = await chunkFileManager.generateChunkURL(startedAt: effectiveStart)

        let writer = ChunkWriter(outputURL: url, sampleRate: targetSampleRate)
        do {
            try writer.start()
        } catch {
            logger.error("Failed to start chunk writer: \(error.localizedDescription)")
            return
        }

        currentWriter = writer
        currentChunkURL = url
        currentChunkStartedAt = effectiveStart
        chunkSampleTime = .zero
        segmentBuffer = []
        preprocessor = AudioPreprocessor(sampleRate: Double(targetSampleRate))

        // Reset per-chunk quality metrics
        chunkRMSSum = 0
        chunkRMSCount = 0
        chunkVADSum = 0
        chunkVADCount = 0

        // Prepend pending buffer from previous short chunk
        if !pendingSegmentBuffer.isEmpty {
            let pendingDuration = Double(pendingSegmentBuffer.count) / Double(targetSampleRate)
            logger.info("Prepending pending buffer (\(pendingDuration, format: .fixed(precision: 1))s) to new chunk")
            activity.log(.chunk, "Prepend pending \(String(format: "%.1f", pendingDuration))s")
            segmentBuffer.append(contentsOf: pendingSegmentBuffer)
            pendingSegmentBuffer = []
            pendingChunkStartedAt = nil
        }

        // Write pre-margin from ring buffer (preprocessed)
        let hwRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        let preMarginSamples = ringBuffer.read(lastSeconds: settings.preMarginSeconds, sampleRate: Int(hwRate))
        if !preMarginSamples.isEmpty {
            var samples16k: [Float]
            if Int(hwRate) != targetSampleRate, let converter = audioConverter {
                samples16k = (try? converter.resample(preMarginSamples, from: hwRate)) ?? preMarginSamples
            } else {
                samples16k = preMarginSamples
            }
            preprocessor.process(&samples16k)
            segmentBuffer.append(contentsOf: samples16k)
        }

        logger.info("New chunk started: \(url.lastPathComponent)")
        activity.log(.chunk, "New chunk: \(url.lastPathComponent)")
    }

    private func writeCurrentAudioToChunk() async {
        guard currentWriter != nil else { return }

        let hwRate = audioEngine.inputNode.outputFormat(forBus: 0).sampleRate
        let analysisWindow: TimeInterval = 0.1
        let hwSampleCount = Int(analysisWindow * hwRate)
        let rawSamples = ringBuffer.read(lastSamples: hwSampleCount)
        guard !rawSamples.isEmpty else { return }

        var samples16k: [Float]
        if Int(hwRate) != targetSampleRate, let converter = audioConverter {
            samples16k = (try? converter.resample(rawSamples, from: hwRate)) ?? rawSamples
        } else {
            samples16k = rawSamples
        }

        preprocessor.process(&samples16k)
        segmentBuffer.append(contentsOf: samples16k)
    }

    private func finalizeCurrentChunk() async {
        guard let writer = currentWriter, let url = currentChunkURL, let startedAt = currentChunkStartedAt else {
            return
        }

        let segmentDuration = Double(segmentBuffer.count) / Double(targetSampleRate)

        // Discard trivially short audio (< 0.5s)
        guard segmentDuration > 0.5, !segmentBuffer.isEmpty else {
            logger.info("Discarding trivially short chunk: \(segmentDuration, format: .fixed(precision: 1))s")
            activity.log(.chunk, "Discarded short chunk (\(String(format: "%.1f", segmentDuration))s)")
            cleanupCurrentChunkState()
            _ = await writer.finish()
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Hold short chunks (< minChunkDuration) in pending buffer for merging with next chunk
        if segmentDuration < settings.minChunkDurationSeconds {
            logger.info("Holding short chunk (\(segmentDuration, format: .fixed(precision: 1))s < \(self.settings.minChunkDurationSeconds, format: .fixed(precision: 0))s min) in pending buffer")
            activity.log(.chunk, "Holding short chunk \(String(format: "%.1f", segmentDuration))s — pending merge")
            pendingSegmentBuffer.append(contentsOf: segmentBuffer)
            if pendingChunkStartedAt == nil {
                pendingChunkStartedAt = startedAt
            }
            cleanupCurrentChunkState()
            _ = await writer.finish()
            try? FileManager.default.removeItem(at: url)
            return
        }

        // Per-segment normalization on buffered audio
        AudioPreprocessor.normalizeSegment(&segmentBuffer)
        activity.log(.chunk, "Normalized segment: \(segmentBuffer.count) samples (\(String(format: "%.1f", segmentDuration))s)")

        // Write normalized audio to chunk writer in batches
        let batchSize = targetSampleRate // 1 second per batch
        var offset = 0
        var sampleTime: CMTime = .zero
        while offset < segmentBuffer.count {
            let end = min(offset + batchSize, segmentBuffer.count)
            let batch = Array(segmentBuffer[offset..<end])
            writer.appendSamples(batch, at: sampleTime)
            let frameDuration = CMTime(value: CMTimeValue(batch.count), timescale: CMTimeScale(targetSampleRate))
            sampleTime = CMTimeAdd(sampleTime, frameDuration)
            offset = end
        }

        let result = await writer.finish()
        cleanupCurrentChunkState()

        guard result.fileSize > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let avgRMSVal = chunkRMSCount > 0 ? chunkRMSSum / Float(chunkRMSCount) : 0
        let vadAvgVal = chunkVADCount > 0 ? chunkVADSum / Float(chunkVADCount) : 0

        await saveChunkRecord(url: url, startedAt: startedAt, duration: result.duration, fileSize: result.fileSize, avgRMS: avgRMSVal, vadAvgProb: vadAvgVal, noiseFloorRMS: noiseFloorRMS)
        chunksRecorded += 1

        let sizeKB = result.fileSize / 1024
        logger.info("Chunk finalized: \(url.lastPathComponent), duration: \(result.duration, format: .fixed(precision: 1))s")
        activity.log(.chunk, "Finalized: \(url.lastPathComponent) \(String(format: "%.1f", result.duration))s \(sizeKB)KB rms=\(String(format: "%.4f", avgRMSVal)) vad=\(String(format: "%.2f", vadAvgVal))")
    }

    /// Force-finalize the pending buffer as a standalone chunk (short but better than losing data).
    private func forceFinalizePendingBuffer() async {
        guard !pendingSegmentBuffer.isEmpty, let pendingStart = pendingChunkStartedAt else { return }

        // Discard trivially short pending audio (< 0.5s)
        let pendingDuration = Double(pendingSegmentBuffer.count) / Double(targetSampleRate)
        guard pendingDuration >= 3.0 else {
            logger.info("Discarding short pending chunk: \(pendingDuration, format: .fixed(precision: 1))s (< 3.0s min)")
            activity.log(.chunk, "Discarded pending < 3s (\(String(format: "%.1f", pendingDuration))s)")
            pendingSegmentBuffer = []
            pendingChunkStartedAt = nil
            return
        }

        let url = await chunkFileManager.generateChunkURL(startedAt: pendingStart)
        let writer = ChunkWriter(outputURL: url, sampleRate: targetSampleRate)
        do {
            try writer.start()
        } catch {
            logger.error("Failed to start writer for pending flush: \(error.localizedDescription)")
            pendingSegmentBuffer = []
            pendingChunkStartedAt = nil
            return
        }

        AudioPreprocessor.normalizeSegment(&pendingSegmentBuffer)

        let batchSize = targetSampleRate
        var offset = 0
        var sampleTime: CMTime = .zero
        while offset < pendingSegmentBuffer.count {
            let end = min(offset + batchSize, pendingSegmentBuffer.count)
            let batch = Array(pendingSegmentBuffer[offset..<end])
            writer.appendSamples(batch, at: sampleTime)
            let frameDuration = CMTime(value: CMTimeValue(batch.count), timescale: CMTimeScale(targetSampleRate))
            sampleTime = CMTimeAdd(sampleTime, frameDuration)
            offset = end
        }

        let result = await writer.finish()
        pendingSegmentBuffer = []
        pendingChunkStartedAt = nil

        guard result.fileSize > 0 else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let avgRMSVal = chunkRMSCount > 0 ? chunkRMSSum / Float(chunkRMSCount) : 0
        let vadAvgVal = chunkVADCount > 0 ? chunkVADSum / Float(chunkVADCount) : 0

        await saveChunkRecord(url: url, startedAt: pendingStart, duration: result.duration, fileSize: result.fileSize, avgRMS: avgRMSVal, vadAvgProb: vadAvgVal, noiseFloorRMS: noiseFloorRMS)
        chunksRecorded += 1

        let sizeKB = result.fileSize / 1024
        logger.info("Pending chunk force-finalized: \(url.lastPathComponent), duration: \(result.duration, format: .fixed(precision: 1))s")
        activity.log(.chunk, "Pending finalized: \(url.lastPathComponent) \(String(format: "%.1f", result.duration))s \(sizeKB)KB rms=\(String(format: "%.4f", avgRMSVal)) vad=\(String(format: "%.2f", vadAvgVal))")
    }

    private func cleanupCurrentChunkState() {
        currentWriter = nil
        currentChunkURL = nil
        currentChunkStartedAt = nil
        segmentBuffer = []
        chunkSampleTime = .zero
    }

    private func splitChunk() async {
        await finalizeCurrentChunk()
        await startNewChunk()
    }

    // MARK: - SwiftData Persistence

    private func saveChunkRecord(url: URL, startedAt: Date, duration: TimeInterval, fileSize: Int64, avgRMS: Float = 0, vadAvgProb: Float = 0, noiseFloorRMS: Float = 0) async {
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
            fileSize: fileSize,
            avgRMS: avgRMS,
            vadAvgProb: vadAvgProb,
            noiseFloorRMS: noiseFloorRMS
        )
        context.insert(chunk)

        do {
            try context.save()
            logger.info("Saved AudioChunk record: \(chunk.fileName)")
        } catch {
            logger.error("Failed to save AudioChunk: \(error.localizedDescription)")
        }
    }

    // MARK: - Route Change Handling

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable:
            guard state == .listening || state == .recording else { return }
            logger.info("Route change detected (reason=\(reason.rawValue)), restarting engine")
            activity.log(.state, "Route change — restarting engine")

            if state == .recording {
                Task { await finalizeCurrentChunk() }
            }

            restartEngine()

        default:
            break
        }
    }

    // MARK: - Interruption Handling

    private func handleInterruptionBegan() {
        guard state == .listening || state == .recording else { return }
        logger.info("Handling interruption began, pausing")
        activity.log(.state, "Interruption — pausing (was \(state.rawValue))")

        if state == .recording {
            Task {
                await finalizeCurrentChunk()
            }
        }

        audioEngine.pause()
        state = .paused
    }

    private func handleInterruptionEnded(shouldResume: Bool) {
        guard state == .paused else { return }

        if shouldResume {
            resumeAfterInterruption()
        } else {
            // Always-on app: force resume even when shouldResume=false (after 2s delay)
            logger.info("shouldResume=false, scheduling forced resume in 2s")
            activity.log(.state, "Interruption ended (shouldResume=false) — will force-resume in 2s")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.state == .paused else { return }
                self.resumeAfterInterruption()
            }
        }
    }

    private func resumeAfterInterruption(attempt: Int = 1) {
        let maxAttempts = 3
        logger.info("Resuming after interruption (attempt \(attempt)/\(maxAttempts))")

        // On retry attempts, reset engine to clear corrupted state
        if attempt > 1 {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
            audioEngine.reset()
            sessionManager.deactivate()
        }

        do {
            try sessionManager.configure()

            // Re-install tap if engine was reset
            if attempt > 1 {
                let inputNode = audioEngine.inputNode
                let hwFormat = inputNode.outputFormat(forBus: 0)
                let hwSampleRate = hwFormat.sampleRate
                inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hwFormat) { [weak self] buffer, _ in
                    self?.handleAudioBuffer(buffer, hardwareSampleRate: hwSampleRate)
                }
                audioEngine.prepare()
            }

            try audioEngine.start()
            state = .listening
            startProcessingLoop()
            BackgroundKeepAlive.shared.resumePlayback()
            activity.log(.state, "Resumed after interruption — Listening (attempt \(attempt))")
        } catch {
            logger.error("Resume attempt \(attempt) failed: \(error.localizedDescription)")
            activity.log(.error, "Resume failed (attempt \(attempt)/\(maxAttempts)): \(error.localizedDescription)")

            if attempt < maxAttempts {
                // Exponential backoff: 2s, 4s, 8s
                let delaySec = 2.0 * pow(2.0, Double(attempt - 1))
                let delayNs = UInt64(delaySec * 1_000_000_000)
                activity.log(.state, "Retry resume in \(Int(delaySec))s...")
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: delayNs)
                    guard let self else { return }
                    // Still need recovery? (not manually restarted)
                    guard self.state == .paused || self.state == .idle else { return }
                    self.resumeAfterInterruption(attempt: attempt + 1)
                }
            } else {
                // All retries exhausted — full restart (more aggressive than resumeAfterInterruption)
                activity.log(.error, "All \(maxAttempts) resume attempts failed — attempting full restartEngine()")
                restartEngine()
            }
        }
    }

    // MARK: - Engine Restart (shared by route change + watchdog)

    /// Restart engine. Does NOT touch watchdog — watchdog is immortal.
    private func restartEngine() {
        // Cancel existing processing (but NOT watchdog)
        processingTask?.cancel()
        processingTask = nil

        // Stop engine and remove tap
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()

        // Full reset clears corrupted internal state ('what' error after interruption)
        audioEngine.reset()

        // Deactivate then reactivate session to clear stale audio state
        sessionManager.deactivate()

        // Re-setup and start
        do {
            try sessionManager.configure()

            let inputNode = audioEngine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)
            let hwSampleRate = hwFormat.sampleRate

            inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hwFormat) { [weak self] buffer, _ in
                self?.handleAudioBuffer(buffer, hardwareSampleRate: hwSampleRate)
            }

            audioEngine.prepare()
            try audioEngine.start()
            state = .listening
            startProcessingLoop()
            BackgroundKeepAlive.shared.resumePlayback()

            logger.info("Engine restarted successfully (\(Int(hwSampleRate))Hz)")
            activity.log(.state, "Engine restarted — Listening (\(Int(hwSampleRate))Hz)")
        } catch {
            logger.error("Failed to restart engine: \(error.localizedDescription)")
            activity.log(.error, "Engine restart failed: \(error.localizedDescription)")
            state = .idle
            // Watchdog remains alive — will retry in 30s
        }
    }
}
