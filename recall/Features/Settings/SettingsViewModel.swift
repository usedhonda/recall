import Foundation
import CoreLocation
import Observation
import SwiftData
import SwiftUI

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

    var currentLocation: CLLocation? {
        telemetry.locationManager.currentLocation
    }

    var locationAnchors: [LocationAnchor] {
        settings.locationAnchors
    }

    var newAnchorName = ""
    var newAnchorRadius: Double = 50

    func addAnchorFromCurrentLocation() {
        guard let location = currentLocation else { return }
        let trimmedName = newAnchorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let anchor = LocationAnchor(
            name: trimmedName.isEmpty ? "anchor \(locationAnchors.count + 1)" : trimmedName,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radius: max(10, newAnchorRadius)
        )
        var anchors = settings.locationAnchors
        anchors.append(anchor)
        settings.locationAnchors = anchors
        newAnchorName = ""
        newAnchorRadius = 50
        telemetry.locationManager.refreshRegions()
        telemetry.locationManager.requestAuthorization()
    }

    func deleteAnchor(id: UUID) {
        var anchors = settings.locationAnchors
        anchors.removeAll { $0.id == id }
        settings.locationAnchors = anchors
        telemetry.locationManager.refreshRegions()
    }

    // MARK: - Network

    var dataPolicy: DataPolicy {
        get { settings.dataPolicy }
        set { settings.dataPolicy = newValue }
    }

    // MARK: - Context Data

    var nowPlayingEnabled: Bool {
        get { telemetry.nowPlayingManager.isEnabled }
        set {
            if newValue {
                telemetry.nowPlayingManager.start()
                settings.nowPlayingEnabled = true
            } else {
                telemetry.nowPlayingManager.stop()
                settings.nowPlayingEnabled = false
            }
        }
    }

    var nowPlayingTitle: String? {
        telemetry.nowPlayingManager.title
    }

    var nowPlayingArtist: String? {
        telemetry.nowPlayingManager.artist
    }

    // MARK: - Glasses (Ray-Ban Meta auto-import)

    var glassesAutoImportEnabled: Bool {
        get { settings.glassesAutoImportEnabled }
        set { settings.glassesAutoImportEnabled = newValue }
    }

    var photoLibraryStatusLabel: String {
        PhotoLibraryAuthorizer.statusName(telemetry.photoLibraryAuthorizer.status).uppercased()
    }

    var photoLibraryStatusColor: Color {
        switch telemetry.photoLibraryAuthorizer.status {
        case .authorized: return RecallTheme.Colors.neonGreen
        case .limited: return RecallTheme.Colors.neonAmber
        default: return RecallTheme.Colors.textSecondary
        }
    }

    var glassesImportedCount: Int {
        telemetry.photoScanCoordinator.totalImported
    }

    var glassesLastImportAt: Date? {
        telemetry.photoScanCoordinator.lastImportedAt
    }

    func applyGlassesToggle(modelContainer: ModelContainer) async {
        if settings.glassesAutoImportEnabled {
            let status = await telemetry.photoLibraryAuthorizer.requestReadWrite()
            guard status == .authorized || status == .limited else {
                settings.glassesAutoImportEnabled = false
                return
            }
            telemetry.photoScanCoordinator.setModelContainer(modelContainer)
            telemetry.photoScanCoordinator.start()
            MediaUploadManager.shared.startProcessing(modelContainer: modelContainer)
        } else {
            telemetry.photoScanCoordinator.stop()
            MediaUploadManager.shared.stopProcessing()
        }
    }

    // MARK: - Reactions

    var webReactionsEnabled: Bool {
        get { settings.webReactionsEnabled }
        set {
            settings.webReactionsEnabled = newValue
            Task { await telemetry.syncReactionSettings() }
        }
    }

    var voiceReactionsEnabled: Bool {
        get { settings.voiceReactionsEnabled }
        set {
            settings.voiceReactionsEnabled = newValue
            Task { await telemetry.syncReactionSettings() }
        }
    }

    var lineDeliveryEnabled: Bool {
        get { settings.lineDeliveryEnabled }
        set {
            settings.lineDeliveryEnabled = newValue
            Task { await telemetry.syncReactionSettings() }
        }
    }

    var vibetermDeliveryEnabled: Bool {
        get { settings.vibetermDeliveryEnabled }
        set {
            settings.vibetermDeliveryEnabled = newValue
            Task { await telemetry.syncReactionSettings() }
        }
    }

    var webMinContentChars: Int {
        get { settings.webMinContentChars }
        set {
            settings.webMinContentChars = newValue
            Task { await telemetry.syncReactionSettings() }
        }
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
