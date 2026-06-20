import AVFoundation
import OSLog

enum MicMode: String {
    case builtIn
    case bluetoothHFP
}

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let logger = Logger(subsystem: "com.example.recall", category: "AudioSession")
    private let session = AVAudioSession.sharedInstance()

    private(set) var desiredMicMode: MicMode = .builtIn

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: session
        )
    }

    func setDesiredMicMode(_ mode: MicMode) {
        desiredMicMode = mode
    }

    /// OSStatus -50 surfaced as an NSError code by AVAudioSession.setActive when the
    /// session cannot interrupt another (non-mixable) active session — structurally
    /// unrecoverable in the background. Recovery paths use this to back off instead
    /// of hammering fresh activations that iOS will keep rejecting.
    static let cannotInterruptOthersCode = 560557684

    static func isCannotInterruptOthers(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == cannotInterruptOthersCode { return true }
        if nsError.localizedDescription.contains("\(cannotInterruptOthersCode)") { return true }
        if let avCode = AVAudioSession.ErrorCode(rawValue: nsError.code), avCode == .cannotInterruptOthers { return true }
        return false
    }

    func configure() throws {
        var options: AVAudioSession.CategoryOptions = [
            .mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP
        ]
        if desiredMicMode == .bluetoothHFP {
            options.insert(.allowBluetooth)
        }
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: options
        )

        if #available(iOS 17.0, *) {
            try session.setPrefersInterruptionOnRouteDisconnect(false)
        }

        try session.setActive(true, options: [])
        let mode = desiredMicMode == .bluetoothHFP ? "HFP+A2DP" : "A2DP only"
        logger.info("Audio session configured (\(mode))")

        // Post-configure snapshot — captures the actual session state right after setActive succeeds.
        // The engine-side `restart enter` snapshot fires before configure(), so this is the only
        // place where we can confirm the session was actually promoted to .playAndRecord.
        let route = session.currentRoute
        let inPort = route.inputs.first?.portType.rawValue ?? "none"
        let outPort = route.outputs.first?.portType.rawValue ?? "none"
        Task { @MainActor in
            ActivityLogger.shared.log(.state, "session configured cat=\(session.category.rawValue) mode=\(session.mode.rawValue) sr=\(session.sampleRate) buf=\(session.ioBufferDuration) in=\(inPort) out=\(outPort) other=\(session.isOtherAudioPlaying)")
        }
    }

    func deactivate() {
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
            logger.info("Audio session deactivated")
        } catch {
            logger.error("Failed to deactivate audio session: \(error.localizedDescription)")
        }
    }

    var currentSampleRate: Double {
        session.sampleRate
    }

    var isOtherAudioPlaying: Bool {
        session.isOtherAudioPlaying
    }

    // MARK: - Input Selection

    var availableInputs: [AVAudioSessionPortDescription] {
        session.availableInputs ?? []
    }

    var currentInput: AVAudioSessionPortDescription? {
        session.currentRoute.inputs.first
    }

    func setPreferredInput(_ port: AVAudioSessionPortDescription?) throws {
        try session.setPreferredInput(port)
        let name = port?.portName ?? "System Default"
        logger.info("Preferred input set to: \(name)")
        Task { @MainActor in
            ActivityLogger.shared.log(.state, "Mic input: \(name)")
        }
    }

    // MARK: - Route Change Handling

    var onRouteChanged: ((_ reason: AVAudioSession.RouteChangeReason) -> Void)?

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        logger.info("Audio route changed: reason=\(reasonValue)")
        onRouteChanged?(reason)
    }

    // MARK: - Media Services Reset Handling

    var onMediaServicesReset: (() -> Void)?

    @objc private func handleMediaServicesReset(_ notification: Notification) {
        // mediaserverd restarted (user "Reset Media Services" or daemon crash).
        // Every audio object (engine, players, session config) is now invalid
        // per Apple docs and must be rebuilt from scratch.
        logger.error("Media services were reset — all audio objects invalid")
        onMediaServicesReset?()
    }

    // MARK: - Interruption Handling

    var onInterruptionBegan: (() -> Void)?
    var onInterruptionEnded: ((_ shouldResume: Bool) -> Void)?

    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            logger.warning("Received interruption notification with invalid type")
            return
        }

        switch type {
        case .began:
            logger.info("Audio session interruption began")
            onInterruptionBegan?()

        case .ended:
            let options = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt
                ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options)
                .contains(.shouldResume)
            logger.info("Audio session interruption ended, shouldResume: \(shouldResume)")

            // Activation is owned solely by the engine's configure() (where the
            // result is observed and -50-classified). A redundant setActive here
            // would be a second cold activation that races the engine and swallows
            // its error.
            onInterruptionEnded?(shouldResume)

        @unknown default:
            logger.warning("Unknown audio session interruption type: \(typeValue)")
        }
    }
}
