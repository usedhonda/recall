import Foundation
import Observation

@Observable
@MainActor
final class SettingsViewModel {
    let settings = AppSettings.shared

    var rmsThreshold: Float {
        get { settings.rmsThreshold }
        set { settings.rmsThreshold = newValue }
    }

    var vadThreshold: Float {
        get { settings.vadThreshold }
        set { settings.vadThreshold = newValue }
    }

    var silenceTimeout: Double {
        get { settings.silenceTimeout }
        set { settings.silenceTimeout = newValue }
    }

    var preMargin: Double {
        get { settings.preMarginSeconds }
        set { settings.preMarginSeconds = newValue }
    }

    var postMargin: Double {
        get { settings.postMarginSeconds }
        set { settings.postMarginSeconds = newValue }
    }

    var chunkDuration: Double {
        get { settings.chunkDurationSeconds }
        set { settings.chunkDurationSeconds = newValue }
    }

    var serverURL: String {
        get { settings.uploadServerURL }
        set { settings.uploadServerURL = newValue }
    }

    var wifiOnly: Bool {
        get { settings.wifiOnlyUpload }
        set { settings.wifiOnlyUpload = newValue }
    }

    var storageCap: Int {
        get { settings.storageCapMB }
        set { settings.storageCapMB = newValue }
    }

    var deviceId: String { settings.deviceId }
}
