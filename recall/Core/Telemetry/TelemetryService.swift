import Foundation
import Observation

enum NowPlayingTelemetryProjection {
    static func legacySnapshot(_ snapshot: NowPlayingSnapshot?, streamEnabled: Bool,
                               legacyAllowed: Bool) -> NowPlayingSnapshot? {
        guard streamEnabled, legacyAllowed else { return nil }
        return snapshot
    }
}

/// Orchestrates all telemetry data streams (health, location)
@Observable
@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    let healthManager = HealthKitManager()
    let locationManager = LocationManager()
    let nowPlayingManager = NowPlayingManager()
    let photoLibraryAuthorizer: PhotoLibraryAuthorizer
    let photoScanCoordinator: PhotoScanCoordinator
    let glassesHandoffReceiver = GlassesHandoffReceiver()

    private(set) var isActive = false

    var hasValidConfig: Bool {
        AppSettings.shared.hasValidTelemetryConfig
    }

    /// Dedicated URLSession with no caching to avoid stale connection issues
    nonisolated let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }()

    private init() {
        let authorizer = PhotoLibraryAuthorizer()
        self.photoLibraryAuthorizer = authorizer
        self.photoScanCoordinator = PhotoScanCoordinator(authorizer: authorizer)
        TelemetryUploader.shared.healthAcknowledgmentHandler = { [weak healthManager] deliveryID, fingerprint, source in
            healthManager?.acknowledgeBackgroundHealth(deliveryID: deliveryID, fingerprint: fingerprint, source: source) ?? false
        }
    }

    // MARK: - Lifecycle

    func start() {
        isActive = true

        if hasValidConfig {
            ActivityLogger.shared.log(.telemetry, "TelemetryService started (server configured)")
        } else {
            ActivityLogger.shared.log(.telemetry, "TelemetryService started (no server — data collection only)")
        }

        // Restore and start health if enabled
        // restoreSettings() sets isEnabled without starting timer (isRestoring flag)
        // so we can await authorization before the first query fires
        healthManager.restoreSettings()
        if healthManager.isEnabled {
            Task {
                let authorized = await healthManager.requestAuthorization()
                if authorized {
                    healthManager.startTimer()
                    await healthManager.queryAndSendFull()  // 24h lookback on launch to catch up
                    ActivityLogger.shared.log(.health, "HealthKit authorized, timer started, first full query sent")
                } else {
                    ActivityLogger.shared.log(.health, "HealthKit authorization denied — health data will not be collected")
                }
            }
        }

        // Restore and start location if enabled
        locationManager.restoreSettings()

        // Restore now playing
        nowPlayingManager.restoreSettings()

        ActivityLogger.shared.log(.telemetry, "Health: \(healthManager.isEnabled), Location: \(locationManager.isEnabled) (auth=\(locationManager.hasAuthorization)), NowPlaying: \(nowPlayingManager.isEnabled)")
    }

    func stop() {
        isActive = false
        healthManager.stopTimer()
        healthManager.isEnabled = false
        locationManager.stopUpdates()
        locationManager.isEnabled = false
        nowPlayingManager.stop()
        ActivityLogger.shared.log(.telemetry, "TelemetryService stopped")
    }

    // MARK: - Location Send

    func sendLocation(_ payload: LocationPayload) async -> LocationSendResult {
        let nowPlayingSnapshot = nowPlayingManager.snapshot
        do {
            let hubExternalID = try await HubTelemetryAdmission.admit(
                route: .gpsDelivery,
                observationID: payload.deliveryID,
                occurredAt: payload.timestamp,
                payload: payload
            )
            if let snapshot = nowPlayingSnapshot {
                do { _ = try await HubTelemetryAdmission.admit(route: .nowPlaying, observationID: snapshot.deliveryID.uuidString, occurredAt: snapshot.timestamp, payload: snapshot) }
                catch { ActivityLogger.shared.log(.telemetry, "nowPlaying Hub admission failed") }
            }
            if !HubTelemetryAdmission.legacyAllowed(.gpsDelivery) {
                guard let hubExternalID,
                      try await HubDeliveryService.shared.isAcknowledged(externalID: hubExternalID) else {
                    return .httpError("Hub admission pending")
                }
                return .sent(status: 200, received: 1, healthReceived: nil, body: nil)
            }
        } catch {
            return .httpError("Hub admission failed")
        }
        guard ConnectivityMonitor.shared.canSendLocation else {
            return .httpError("waiting for WiFi (location wifi-only)")
        }
        guard hasValidConfig,
              let token = KeychainHelper.shared.getToken() else {
            return .httpError("not configured")
        }

        let serverURL = AppSettings.shared.telemetryServerURL
        guard let url = URL(string: "\(serverURL)/api/telemetry") else {
            return .httpError("invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")

        let batch = TelemetrySampleBatch(
            samples: [TelemetrySample(from: payload)],
            nowPlaying: NowPlayingTelemetryProjection.legacySnapshot(
                nowPlayingSnapshot,
                streamEnabled: nowPlayingManager.isEnabled,
                legacyAllowed: HubTelemetryAdmission.legacyAllowed(.nowPlaying)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            request.httpBody = try encoder.encode(batch)
            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .httpError("invalid response")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                return .httpError("HTTP \(httpResponse.statusCode): \(body)")
            }

            let decoded = try? JSONDecoder().decode(TelemetryResponse.self, from: data)
            let body = String(data: data, encoding: .utf8)
            return .sent(
                status: httpResponse.statusCode,
                received: decoded?.received,
                healthReceived: nil,
                body: body
            )
        } catch {
            return .httpError(error.localizedDescription)
        }
    }

    // MARK: - Background Location Queue + Upload

    func queueAndUploadBackground(_ sample: LocationSample) async {
        guard await LocationQueue.shared.enqueue(sample) else {
            ActivityLogger.shared.log(.telemetry, "GPS queue admission rejected; not stored")
            return
        }
        await TelemetryUploader.shared.triggerUpload()
    }

    // MARK: - Health Send

    /// Durable foreground Hub binding seam. Registration happens before any
    /// receipt lookup so a delayed acknowledgement can reconcile the exact
    /// original delivery after this call returns `.sending`.
    func registerHubHealthPending(_ payload: HealthPayload, fingerprint: String,
                                  externalID: String,
                                  ledger: TelemetryBatchLedger = .shared) async -> HealthSendResult {
        do {
            try await ledger.recordHubHealthPending(
                deliveryID: payload.deliveryID.uuidString,
                fingerprint: fingerprint,
                externalID: externalID,
                collectedAt: payload.collectedAt
            )
            return .sending
        } catch {
            return .error("Hub Health binding failed: \(error.localizedDescription)")
        }
    }

    func sendHealth(_ payload: HealthPayload) async -> HealthSendResult {
        // A foreground tick is also a receipt-reconciliation opportunity; do
        // not depend on a background URLSession callback when Location is off.
        await TelemetryUploader.shared.reconcileHubHealthAcknowledgments()
        let nowPlayingSnapshot = nowPlayingManager.snapshot
        do {
            let hubExternalID = try await HubTelemetryAdmission.admit(
                route: .healthSnapshot,
                observationID: payload.deliveryID.uuidString,
                occurredAt: payload.collectedAt,
                payload: payload
            )
            if let snapshot = nowPlayingSnapshot {
                do { _ = try await HubTelemetryAdmission.admit(route: .nowPlaying, observationID: snapshot.deliveryID.uuidString, occurredAt: snapshot.timestamp, payload: snapshot) }
                catch { ActivityLogger.shared.log(.telemetry, "nowPlaying Hub admission failed") }
            }
            if !HubTelemetryAdmission.legacyAllowed(.healthSnapshot) {
                guard let hubExternalID else {
                    return .error("Hub admission missing external ID")
                }
                let bindingFingerprint = HealthKitManager.fingerprint(payload)
                let binding = await registerHubHealthPending(payload, fingerprint: bindingFingerprint,
                                                              externalID: hubExternalID)
                if case .error = binding {
                    return binding
                }
                guard try await HubDeliveryService.shared.isAcknowledged(externalID: hubExternalID) else {
                    return .sending
                }
                return .sent(status: 200, body: "")
            }
        } catch {
            return .error("Hub admission failed")
        }
        guard ConnectivityMonitor.shared.canSendHealth else {
            return .error("waiting for WiFi (health wifi-only)")
        }
        guard hasValidConfig,
              let token = KeychainHelper.shared.getToken() else {
            return .error("not configured")
        }

        let serverURL = AppSettings.shared.telemetryServerURL
        guard let url = URL(string: "\(serverURL)/api/telemetry") else {
            return .error("invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")

        let batch = TelemetrySampleBatch(
            samples: [],
            health2: payload,
            nowPlaying: NowPlayingTelemetryProjection.legacySnapshot(
                nowPlayingSnapshot,
                streamEnabled: nowPlayingManager.isEnabled,
                legacyAllowed: HubTelemetryAdmission.legacyAllowed(.nowPlaying)
            )
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            let body = try encoder.encode(batch)
            request.httpBody = body
            ActivityLogger.shared.log(.telemetry, "Telemetry POST (fg): body=\(body.count)B health2=[\(payload.recordsLogSummary())]")

            let (data, response) = try await urlSession.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("invalid response")
            }

            let respBody = String(data: data, encoding: .utf8) ?? ""

            guard (200...299).contains(httpResponse.statusCode) else {
                return .error("HTTP \(httpResponse.statusCode): \(respBody)")
            }

            do {
                _ = try TelemetryAcknowledgment.validate(
                    data: data,
                    statusCode: httpResponse.statusCode,
                    requiresHealth: true
                )
            } catch {
                return .error("invalid health acknowledgement: \(error.localizedDescription)")
            }

            ActivityLogger.shared.log(.telemetry, "Health data sent: HTTP \(httpResponse.statusCode)")
            return .sent(status: httpResponse.statusCode, body: respBody)
        } catch {
            return .error(error.localizedDescription)
        }
    }


    // MARK: - Reaction Settings Sync

    func syncReactionSettings() async {
        guard hasValidConfig,
              let token = KeychainHelper.shared.getToken() else { return }

        let serverURL = AppSettings.shared.telemetryServerURL
        guard let url = URL(string: "\(serverURL)/api/recall-settings") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "webReactionsEnabled": AppSettings.shared.webReactionsEnabled,
            "voiceReactionsEnabled": AppSettings.shared.voiceReactionsEnabled,
            "lineDeliveryEnabled": AppSettings.shared.lineDeliveryEnabled,
            "vibetermDeliveryEnabled": AppSettings.shared.vibetermDeliveryEnabled,
            "webMinContentChars": AppSettings.shared.webMinContentChars,
            "reactionMode": AppSettings.shared.reactionMode.rawValue,
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return }
            ActivityLogger.shared.log(.telemetry, "Reaction settings synced: HTTP \(httpResponse.statusCode)")
        } catch {
            ActivityLogger.shared.log(.telemetry, "Reaction settings sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Connection Test

    func testConnection() async -> Bool {
        guard let token = KeychainHelper.shared.getToken() else { return false }
        let serverURL = AppSettings.shared.telemetryServerURL
        guard let url = URL(string: "\(serverURL)/api/telemetry") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        // Send empty batch as connection test
        let batch = TelemetrySampleBatch(samples: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try? encoder.encode(batch)

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }
}
