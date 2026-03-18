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

    // MARK: - Telemetry

    private let telemetry = TelemetryService.shared

    var telemetryServerURL: String {
        get { settings.telemetryServerURL }
        set { settings.telemetryServerURL = newValue }
    }

    var tokenInput: String = ""

    var hasToken: Bool {
        KeychainHelper.shared.hasToken
    }

    var hasValidConfig: Bool {
        settings.hasValidTelemetryConfig
    }

    func saveToken() {
        guard !tokenInput.isEmpty else { return }
        try? KeychainHelper.shared.saveToken(tokenInput)
        tokenInput = ""
    }

    func deleteToken() {
        KeychainHelper.shared.deleteToken()
        tokenInput = ""
    }

    var isTestingConnection = false
    var connectionTestResult: String?

    func testConnection() async {
        isTestingConnection = true
        connectionTestResult = nil
        let success = await telemetry.testConnection()
        connectionTestResult = success ? "OK - Connected" : "Failed - Check URL and token"
        isTestingConnection = false
    }

    var healthEnabled: Bool {
        get { telemetry.healthManager.isEnabled }
        set {
            if newValue {
                Task {
                    let authorized = await telemetry.healthManager.requestAuthorization()
                    if authorized {
                        telemetry.healthManager.isEnabled = true
                        telemetry.healthManager.startTimer()
                        settings.healthEnabled = true
                    }
                }
            } else {
                telemetry.healthManager.isEnabled = false
                telemetry.healthManager.stopTimer()
                settings.healthEnabled = false
            }
        }
    }

    var locationEnabled: Bool {
        get { telemetry.locationManager.isEnabled }
        set {
            if newValue {
                if !telemetry.locationManager.hasAuthorization {
                    telemetry.locationManager.requestAuthorization()
                }
                telemetry.locationManager.isEnabled = true
            } else {
                telemetry.locationManager.isEnabled = false
            }
        }
    }

    var locationBackgroundEnabled: Bool {
        get { telemetry.locationManager.backgroundEnabled }
        set { telemetry.locationManager.backgroundEnabled = newValue }
    }

    var telemetrySendInterval: Double {
        get { telemetry.locationManager.minSendInterval }
        set { telemetry.locationManager.minSendInterval = newValue }
    }

    var lastHealthQueryTime: Date? {
        telemetry.healthManager.lastQueryAt
    }

    var lastLocationSentTime: Date? {
        telemetry.locationManager.lastSentTime
    }

    // MARK: - QR Code

    var showQRScanner = false
    var qrScanResult: String?

    func applyQRCode(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              url.scheme == "openclaw", url.host == "connect",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value,
              !host.isEmpty else { return false }

        let port = items.first(where: { $0.name == "port" })?.value ?? "18789"
        settings.telemetryServerURL = "http://\(host):\(port)"
        settings.uploadServerURL = "http://\(host):8300"

        if let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty {
            try? KeychainHelper.shared.saveToken(token)
        }

        qrScanResult = "Configured: \(host)"
        ActivityLogger.shared.log(.network, "QR config applied: host=\(host) port=\(port)")
        return true
    }
}
