import Foundation
import Observation

/// Single axis controlling when telemetry/upload is allowed to leave the device.
/// Replaces the old DATA SAVER + per-stream WiFi-only toggles.
enum DataPolicy: String, CaseIterable {
    case any            // send on any network, foreground or background
    case wifiOnly       // send only on WiFi (not expensive/constrained)
    case wifiForeground // send only on WiFi while foregrounded (travel mode)

    var displayLabel: String {
        switch self {
        case .any: return "ANY NETWORK"
        case .wifiOnly: return "WI-FI ONLY"
        case .wifiForeground: return "WI-FI + FOREGROUND"
        }
    }
}

/// Stance recall asks Chi to take when reacting to surrounding conversation.
/// Travels per-chunk in upload metadata (`reaction_mode`); the Gateway applies
/// the latest chunk's mode at react time. `auto` keeps the server-side
/// basic/combat auto-detection (existing behavior, default).
enum ReactionMode: String, CaseIterable {
    case auto       // server-side auto-detect (basic/combat) — default
    case question   // ask pointed, probing questions
    case rebut      // counter-argue
    case executive  // sharp, decisive executive opinions/counters

    var displayLabel: String {
        switch self {
        case .auto: return "AUTO"
        case .question: return "QUESTION"
        case .rebut: return "REBUT"
        case .executive: return "EXECUTIVE"
        }
    }
}

struct LocationAnchor: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double

    init(
        id: UUID = UUID(),
        name: String,
        latitude: Double,
        longitude: Double,
        radius: Double
    ) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
    }
}

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

    var chunkDurationSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "chunkDurationSeconds").nonZero ?? 30.0 }
        set { UserDefaults.standard.set(newValue, forKey: "chunkDurationSeconds") }
    }

    var minChunkDurationSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "minChunkDurationSeconds").nonZero ?? 2.0 }
        set { UserDefaults.standard.set(newValue, forKey: "minChunkDurationSeconds") }
    }

    var uploadServerURL: String {
        get { UserDefaults.standard.string(forKey: "uploadServerURL") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "uploadServerURL") }
    }

    var debugLogHost: String {
        get {
            let val = UserDefaults.standard.string(forKey: "debugLogHost") ?? ""
            return val.isEmpty ? "100.89.110.24" : val
        }
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

    var dataPolicy: DataPolicy {
        get { DataPolicy(rawValue: UserDefaults.standard.string(forKey: "dataPolicy") ?? "") ?? .any }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "dataPolicy") }
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

    var locationAnchors: [LocationAnchor] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "locationAnchors") else { return [] }
            return (try? JSONDecoder().decode([LocationAnchor].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "locationAnchors")
            }
        }
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

    /// Which stance Chi takes when reacting. Default `.auto` preserves the
    /// existing server-side basic/combat auto-detection.
    var reactionMode: ReactionMode {
        get { ReactionMode(rawValue: UserDefaults.standard.string(forKey: "reactionMode") ?? "") ?? .auto }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "reactionMode") }
    }

    // MARK: - Context Data Settings

    /// Auto-import photos and videos taken with Ray-Ban Meta smart glasses.
    var glassesAutoImportEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: "glassesAutoImportEnabled") == nil { return true }
            return UserDefaults.standard.bool(forKey: "glassesAutoImportEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "glassesAutoImportEnabled") }
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
