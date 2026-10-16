import Foundation

final class RecordingStateManager {
    static let shared = RecordingStateManager()

    static let appGroupID = "group.com.example.recall"
    static let darwinNotificationName = "com.example.recall.recordingStateChanged"

    private let isRecordingKey = "isRecording"
    private let userStopIntentKey = "userStopIntent"
    private let defaults: UserDefaults

    private init() {
        defaults = UserDefaults(suiteName: Self.appGroupID) ?? .standard
    }

    var isRecording: Bool {
        get { defaults.bool(forKey: isRecordingKey) }
        set {
            defaults.set(newValue, forKey: isRecordingKey)
            defaults.synchronize()
            postDarwinNotification()
        }
    }

    /// Durable user stop intent. This is intentionally separate from
    /// AudioRecordingEngine.userStopped, which is an in-memory watchdog guard.
    var userStopIntent: Bool {
        get { defaults.bool(forKey: userStopIntentKey) }
        set {
            defaults.set(newValue, forKey: userStopIntentKey)
            defaults.synchronize()
        }
    }

    /// Control Center / App Intents switch. An OFF is saved as the durable stop intent in the
    /// same step, because the app process may not exist yet to apply it: a later launch,
    /// retry or pending start must still find the owner's stop.
    func applyExternalToggle(_ on: Bool) {
        if !on { userStopIntent = true }
        isRecording = on
    }

    func postDarwinNotification() {
        let name = CFNotificationName(Self.darwinNotificationName as CFString)
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, name, nil, nil, true)
    }

    func observeDarwinNotification(callback: @escaping () -> Void) -> DarwinNotificationToken {
        DarwinNotificationToken(name: Self.darwinNotificationName, callback: callback)
    }
}

final class DarwinNotificationToken {
    private let name: String
    private var callback: (() -> Void)?

    init(name: String, callback: @escaping () -> Void) {
        self.name = name
        self.callback = callback

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { (_, observer, _, _, _) in
                guard let observer else { return }
                let token = Unmanaged<DarwinNotificationToken>.fromOpaque(observer).takeUnretainedValue()
                token.callback?()
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterRemoveObserver(center, observer, CFNotificationName(name as CFString), nil)
    }
}
