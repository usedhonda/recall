import Foundation

/// What the server is told about the microphone, so that recording which stopped against
/// the owner's wishes is visible instead of looking like a quiet day.
///
/// On 2026-09-17 three stretches were found where recording was off and nobody could see
/// it: another app held the audio session for two hours, and the server could not tell
/// any of it from silence. Agreed with oc-general the same day: the server alarms when a
/// `blocked:*` or `stopped:internal` state has lasted 10 minutes. `stopped:user` is
/// information only — the owner switches recording off on purpose, for battery among other
/// reasons, and an alarm there would just be nagging.
enum AudioStateSignal {
    enum Engine {
        case none, idle, listening, recording, paused
    }

    /// Survives engine recreation and app restarts, so "when did recording last capture
    /// anything" has an answer even straight after a relaunch.
    static let lastChunkKey = "audioState.lastChunkAt"

    /// - Parameters:
    ///   - toggleOn: the owner's own switch for the audio stream. Off means off by choice,
    ///     whatever the engine is doing.
    ///   - engine: the engine's state, or `.none` if none exists.
    ///   - activationBlocked: iOS is refusing to hand the audio session back.
    static func describe(toggleOn: Bool, engine: Engine, activationBlocked: Bool) -> String {
        guard toggleOn else { return "stopped:user" }
        switch engine {
        case .none, .idle:
            return "stopped:internal"
        case .paused:
            // Paused means iOS took the session. Once a resume has been refused the reason
            // is known; before that it is still an interruption in progress (a call, Siri).
            return activationBlocked ? "blocked:cannotInterruptOthers" : "blocked:interrupted"
        case .listening:
            return "listening"
        case .recording:
            return "recording"
        }
    }

    /// Listening and recording trade places with every sentence. Only a change in whether
    /// audio is being captured at all is worth a message to the server.
    static func healthClass(of state: String) -> String {
        state == "listening" || state == "recording" ? "capturing" : state
    }
}
