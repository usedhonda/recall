import Foundation

final class RecordingStateManager {
    static let shared = RecordingStateManager()

    static let appGroupID = "group.com.example.recall"
    static let darwinNotificationName = "com.example.recall.recordingStateChanged"

    private let isRecordingKey = "isRecording"
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
