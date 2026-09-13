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
/// Silero is recurrent: it decides whether the current 256 ms is speech partly from
/// what came before, carried in a state it hands back with every result. recall feeds
/// it the microphone as one unbroken sequence — contiguous, non-overlapping windows,
/// state passed forward — and lets the library's own state machine (Silero's
/// hysteresis: a high bar to start speaking, a lower one to stop, and a minimum
/// silence before it believes the sentence ended) raise the start and end events.
///
/// Two earlier shapes were wrong and each broke it in its own direction. Feeding 100 ms
/// padded out to 256 ms into a state that was never reset made detection collapse to
/// silence within hours. Re-scoring the newest 256 ms from a fresh state every 100 ms —
/// overlapping windows, no memory — made the probability meaningless instead: measured
/// against 883 labelled recordings on 2026-09-13, chunks that turned out to contain no
/// speech at all scored a median 0.41, and chunks of real speech scored 0.40. A detector
/// that cannot tell the two apart passes silence to the transcriber, which answers with
/// a stock phrase it learned from subtitles, and that fiction reaches Chi.
actor VADService {
    static let windowSamples = VadManager.chunkSize

    private let logger = Logger(subsystem: "com.recall", category: "VAD")
    private let manager: VadManager
    private var streamState: VadStreamState
    /// Audio that arrived since the last full window. Silero wants exactly
    /// `windowSamples` at a time; anything left over waits here for the next tick.
    private var pending: [Float] = []

    init() async throws {
        self.manager = try await VadManager()
        self.streamState = VadStreamState.initial()
        logger.info("VADService initialized")
    }

    /// Feed newly captured 16 kHz mono audio. Returns one result per complete window
    /// the audio completed — usually one, occasionally none or two, depending on how
    /// much arrived. Callers must pass each sample exactly once, in order.
    func feed(_ samples: [Float]) async throws -> [VADResult] {
        pending.append(contentsOf: samples)
        var results: [VADResult] = []

        while pending.count >= Self.windowSamples {
            let window = Array(pending.prefix(Self.windowSamples))
            pending.removeFirst(Self.windowSamples)

            let result = try await manager.processStreamingChunk(window, state: streamState)
            streamState = result.state

            let event: VADResult.Event
            switch result.event?.kind {
            case .speechStart: event = .speechStart
            case .speechEnd: event = .speechEnd
            case nil: event = .none
            }
            results.append(VADResult(probability: result.probability, event: event))
        }

        return results
    }

    /// Forget the sentence so far. Used when capture stops and restarts, where the
    /// audio either side of the break has nothing to do with the other.
    func reset() {
        streamState = VadStreamState.initial()
        pending.removeAll()
    }
}
