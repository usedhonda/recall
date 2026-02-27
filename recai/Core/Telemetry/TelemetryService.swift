import Foundation
import Observation

/// Orchestrates all telemetry data streams (health, location)
@Observable
@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    let healthManager = HealthKitManager()
    let locationManager = LocationManager()

    private(set) var isActive = false

    var hasValidConfig: Bool {
        AppSettings.shared.hasValidTelemetryConfig
    }

    private init() {}

    // MARK: - Lifecycle

    func start() {
        isActive = true

        if hasValidConfig {
            ActivityLogger.shared.log(.telemetry, "TelemetryService started (server configured)")
        } else {
            ActivityLogger.shared.log(.telemetry, "TelemetryService started (no server — data collection only)")
        }

        // Restore and start health if enabled
        healthManager.restoreSettings()
        if healthManager.isEnabled {
            Task {
                let authorized = await healthManager.requestAuthorization()
                if authorized {
                    healthManager.startTimer()
                    ActivityLogger.shared.log(.health, "HealthKit authorized and timer started")
                }
            }
        }

        // Restore and start location if enabled
        locationManager.restoreSettings()
        ActivityLogger.shared.log(.telemetry, "Health: \(healthManager.isEnabled), Location: \(locationManager.isEnabled) (auth=\(locationManager.hasAuthorization))")
    }

    func stop() {
        isActive = false
        healthManager.stopTimer()
        healthManager.isEnabled = false
        locationManager.stopUpdates()
        locationManager.isEnabled = false
        ActivityLogger.shared.log(.telemetry, "TelemetryService stopped")
    }

    // MARK: - Location Send

    func sendLocation(_ payload: LocationPayload) async -> LocationSendResult {
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
        request.setValue("recai-ios/1.0", forHTTPHeaderField: "User-Agent")

        let batch = TelemetrySampleBatch(
            samples: [
                TelemetrySample(
                    id: UUID().uuidString,
                    lat: payload.latitude,
                    lon: payload.longitude,
                    accuracy: payload.accuracy,
                    altitude: payload.altitude,
                    speed: payload.speed,
                    timestamp: payload.timestamp
                ),
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            request.httpBody = try encoder.encode(batch)
            let (data, response) = try await URLSession.shared.data(for: request)

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
        await LocationQueue.shared.enqueue(sample)
        await TelemetryUploader.shared.triggerUpload()
    }

    // MARK: - Health Send

    func sendHealth(_ summary: HealthSummary) async -> HealthSendResult {
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
        request.setValue("recai-ios/1.0", forHTTPHeaderField: "User-Agent")

        let batch = TelemetrySampleBatch(samples: [], health: summary)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        do {
            request.httpBody = try encoder.encode(batch)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .error("invalid response")
            }

            let body = String(data: data, encoding: .utf8) ?? ""

            guard (200...299).contains(httpResponse.statusCode) else {
                return .error("HTTP \(httpResponse.statusCode): \(body)")
            }

            ActivityLogger.shared.log(.telemetry, "Health data sent: HTTP \(httpResponse.statusCode)")
            return .sent(status: httpResponse.statusCode, body: body)
        } catch {
            return .error(error.localizedDescription)
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
        request.setValue("recai-ios/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        // Send empty batch as connection test
        let batch = TelemetrySampleBatch(samples: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try? encoder.encode(batch)

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200...299).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }
}
