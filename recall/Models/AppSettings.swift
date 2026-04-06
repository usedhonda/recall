import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var rmsThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "rmsThreshold")).nonZero ?? 0.002 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "rmsThreshold") }
    }

    var vadThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "vadThreshold")).nonZero ?? 0.25 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "vadThreshold") }
    }

    var silenceTimeout: TimeInterval {
        get { UserDefaults.standard.double(forKey: "silenceTimeout").nonZero ?? 1.5 }
        set { UserDefaults.standard.set(newValue, forKey: "silenceTimeout") }
    }

    var preMarginSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "preMarginSeconds").nonZero ?? 3.0 }
        set { UserDefaults.standard.set(newValue, forKey: "preMarginSeconds") }
    }

    var postMarginSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "postMarginSeconds").nonZero ?? 2.0 }
        set { UserDefaults.standard.set(newValue, forKey: "postMarginSeconds") }
    }

    var chunkDurationSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "chunkDurationSeconds").nonZero ?? 30.0 }
        set { UserDefaults.standard.set(newValue, forKey: "chunkDurationSeconds") }
    }

    var minChunkDurationSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "minChunkDurationSeconds").nonZero ?? 2.0 }
        set { UserDefaults.standard.set(newValue, forKey: "minChunkDurationSeconds") }
    }

    var vadUploadMinProb: Float {
        get { Float(UserDefaults.standard.double(forKey: "vadUploadMinProb")).nonZero ?? 0.05 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "vadUploadMinProb") }
    }

    var uploadServerURL: String {
        get { UserDefaults.standard.string(forKey: "uploadServerURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "uploadServerURL") }
    }

    var debugLogHost: String {
        get { UserDefaults.standard.string(forKey: "debugLogHost") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "debugLogHost") }
    }

    var preferredMicMode: String {
        get { UserDefaults.standard.string(forKey: "preferredMicMode") ?? MicMode.builtIn.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "preferredMicMode") }
    }

    var deviceId: String {
        get {
            if let id = UserDefaults.standard.string(forKey: "deviceId"), !id.isEmpty {
                return id
            }
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: "deviceId")
            return id
        }
        set { UserDefaults.standard.set(newValue, forKey: "deviceId") }
    }

    var wifiOnlyUpload: Bool {
        get {
            if UserDefaults.standard.object(forKey: "wifiOnlyUpload") == nil { return true }
            return UserDefaults.standard.bool(forKey: "wifiOnlyUpload")
        }
        set { UserDefaults.standard.set(newValue, forKey: "wifiOnlyUpload") }
    }

    var healthWifiOnly: Bool {
        get {
            if UserDefaults.standard.object(forKey: "healthWifiOnly") == nil { return false }
            return UserDefaults.standard.bool(forKey: "healthWifiOnly")
        }
        set { UserDefaults.standard.set(newValue, forKey: "healthWifiOnly") }
    }

    var locationWifiOnly: Bool {
        get {
            if UserDefaults.standard.object(forKey: "locationWifiOnly") == nil { return false }
            return UserDefaults.standard.bool(forKey: "locationWifiOnly")
        }
        set { UserDefaults.standard.set(newValue, forKey: "locationWifiOnly") }
    }

    var storageCapMB: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "storageCapMB")
            return val > 0 ? val : 1024
        }
        set { UserDefaults.standard.set(newValue, forKey: "storageCapMB") }
    }

    // MARK: - Telemetry Settings

    var telemetryServerURL: String {
        get {
            let url = UserDefaults.standard.string(forKey: "telemetryServerURL") ?? ""
            // Auto-migrate: telemetry endpoint is on Gateway :18789, not ClawGate :8765
            if url.contains(":8765") {
                let fixed = url.replacingOccurrences(of: ":8765", with: ":18789")
                UserDefaults.standard.set(fixed, forKey: "telemetryServerURL")
                return fixed
            }
            return url
        }
        set { UserDefaults.standard.set(newValue, forKey: "telemetryServerURL") }
    }

    var healthEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "telemetryHealthEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "telemetryHealthEnabled") }
    }

    var locationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "telemetryLocationEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "telemetryLocationEnabled") }
    }

    var locationBackgroundEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "telemetryLocationBackgroundEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "telemetryLocationBackgroundEnabled") }
    }

    var telemetrySendInterval: TimeInterval {
        get {
            let val = UserDefaults.standard.double(forKey: "telemetrySendInterval")
            return val > 0 ? val : 15
        }
        set { UserDefaults.standard.set(newValue, forKey: "telemetrySendInterval") }
    }

    /// True when both server URL and bearer token are configured
    var hasValidTelemetryConfig: Bool {
        !telemetryServerURL.isEmpty && KeychainHelper.shared.hasToken
    }

    // MARK: - Reaction Settings

    var webReactionsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "webReactionsEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "webReactionsEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "webReactionsEnabled") }
    }

    var voiceReactionsEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "voiceReactionsEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "voiceReactionsEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "voiceReactionsEnabled") }
    }

    var lineDeliveryEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "lineDeliveryEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "lineDeliveryEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "lineDeliveryEnabled") }
    }

    var vibetermDeliveryEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "vibetermDeliveryEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "vibetermDeliveryEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "vibetermDeliveryEnabled") }
    }

    // MARK: - Context Data Settings

    var motionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "motionEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "motionEnabled") }
    }

    var nowPlayingEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "nowPlayingEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "nowPlayingEnabled") }
    }

    var webMinContentChars: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "webMinContentChars")
            return UserDefaults.standard.object(forKey: "webMinContentChars") != nil ? val : 200
        }
        set { UserDefaults.standard.set(newValue, forKey: "webMinContentChars") }
    }

    private init() {}
}

private extension Float {
    var nonZero: Float? { self != 0 ? self : nil }
}

private extension Double {
    var nonZero: Double? { self != 0 ? self : nil }
}
