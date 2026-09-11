import FluidAudio
import OSLog

/// Result from a single VAD inference pass.
struct VADResult {
    enum Event {
        case speechStart
        case speechEnd
        case none
    }

    let probability: Float
    let event: Event
}

/// Wraps FluidAudio's VadManager. Silero VAD runs on CoreML / ANE for efficient
/// always-on inference.
///
/// The model expects `windowSamples` contiguous samples (4096 = 256 ms at 16 kHz)
/// per inference. recall evaluates the latest 256 ms window on every 100 ms tick,
/// each from a fresh model state: overlapping windows cannot feed one recurrent
/// state, and a shorter input gets padded. (Previously each call carried 100 ms of
/// audio plus 156 ms of flat padding into a recurrent state that was never reset.)
actor VADService {
    static let windowSamples = VadManager.chunkSize

    private let logger = Logger(subsystem: "com.recall", category: "VAD")
    private let manager: VadManager

    init() async throws {
        self.manager = try await VadManager()
        logger.info("VADService initialized")
    }

    /// Speech probability of the most recent `windowSamples` of 16 kHz mono Float32 audio.
    func evaluate(window samples: [Float]) async throws -> VADResult {
        let window = samples.count > Self.windowSamples ? Array(samples.suffix(Self.windowSamples)) : samples
        let results = try await manager.process(window)
        return VADResult(probability: results.first?.probability ?? 0, event: .none)
    }
}
