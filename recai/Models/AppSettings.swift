import Foundation
import Observation

@Observable
final class AppSettings {
    static let shared = AppSettings()

    var rmsThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "rmsThreshold")).nonZero ?? 0.005 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "rmsThreshold") }
    }

    var vadThreshold: Float {
        get { Float(UserDefaults.standard.double(forKey: "vadThreshold")).nonZero ?? 0.5 }
        set { UserDefaults.standard.set(Double(newValue), forKey: "vadThreshold") }
    }

    var silenceTimeout: TimeInterval {
        get { UserDefaults.standard.double(forKey: "silenceTimeout").nonZero ?? 3.0 }
        set { UserDefaults.standard.set(newValue, forKey: "silenceTimeout") }
    }

    var preMarginSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "preMarginSeconds").nonZero ?? 2.0 }
        set { UserDefaults.standard.set(newValue, forKey: "preMarginSeconds") }
    }

    var postMarginSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "postMarginSeconds").nonZero ?? 2.0 }
        set { UserDefaults.standard.set(newValue, forKey: "postMarginSeconds") }
    }

    var chunkDurationSeconds: TimeInterval {
        get { UserDefaults.standard.double(forKey: "chunkDurationSeconds").nonZero ?? 300.0 }
        set { UserDefaults.standard.set(newValue, forKey: "chunkDurationSeconds") }
    }

    var uploadServerURL: String {
        get { UserDefaults.standard.string(forKey: "uploadServerURL") ?? "http://192.0.2.10:8300" }
        set { UserDefaults.standard.set(newValue, forKey: "uploadServerURL") }
    }

    var debugLogHost: String {
        get { UserDefaults.standard.string(forKey: "debugLogHost") ?? "192.0.2.11" }
        set { UserDefaults.standard.set(newValue, forKey: "debugLogHost") }
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

    var storageCapMB: Int {
        get {
            let val = UserDefaults.standard.integer(forKey: "storageCapMB")
            return val > 0 ? val : 1024
        }
        set { UserDefaults.standard.set(newValue, forKey: "storageCapMB") }
    }

    private init() {}
}

private extension Float {
    var nonZero: Float? { self != 0 ? self : nil }
}

private extension Double {
    var nonZero: Double? { self != 0 ? self : nil }
}
