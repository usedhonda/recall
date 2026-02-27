import AVFoundation
import OSLog

final class AudioSessionManager {
    static let shared = AudioSessionManager()

    private let logger = Logger(subsystem: "com.example.recai", category: "AudioSession")
    private let session = AVAudioSession.sharedInstance()

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
    }

    func configure() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true, options: [])
        logger.info("Audio session configured and activated")
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

            if shouldResume {
                do {
                    try session.setActive(true, options: [])
                    logger.info("Audio session reactivated after interruption")
                } catch {
                    logger.error("Failed to reactivate audio session: \(error.localizedDescription)")
                }
            }
            onInterruptionEnded?(shouldResume)

        @unknown default:
            logger.warning("Unknown audio session interruption type: \(typeValue)")
        }
    }
}
