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

/// Wraps FluidAudio's VadManager for streaming voice activity detection.
/// Silero VAD runs on CoreML / ANE for efficient always-on inference.
actor VADService {
    private let logger = Logger(subsystem: "com.recai", category: "VAD")
    private let manager: VadManager
    private var streamState: VadStreamState

    init() async throws {
        self.manager = try await VadManager()
        self.streamState = await manager.makeStreamState()
        logger.info("VADService initialized")
    }

    /// Process a chunk of 16kHz mono Float32 samples through Silero VAD.
    func processChunk(_ samples: [Float]) async throws -> VADResult {
        let result = try await manager.processStreamingChunk(
            samples,
            state: streamState,
            config: .default,
            returnSeconds: true,
            timeResolution: 2
        )
        streamState = result.state

        let event: VADResult.Event
        if let vadEvent = result.event {
            switch vadEvent.kind {
            case .speechStart:
                event = .speechStart
                logger.debug("Speech start detected, prob: \(result.probability)")
            case .speechEnd:
                event = .speechEnd
                logger.debug("Speech end detected, prob: \(result.probability)")
            }
        } else {
            event = .none
        }

        return VADResult(probability: result.probability, event: event)
    }

    /// Reset the streaming state (e.g. after a long pause or interruption).
    func reset() async {
        streamState = await manager.makeStreamState()
        logger.info("VAD stream state reset")
    }
}
