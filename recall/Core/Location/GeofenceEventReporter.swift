import CoreLocation
import Foundation
import UIKit

/// Posts an explicit geofence crossing the moment iOS reports it.
///
/// The greetings ("いってらっしゃい" / "ただいま") are what this exists for. The server's
/// own distance check needs 3 samples over 180 s (10 min under the night guard) before it
/// will call a departure, because it has to defend itself against drifting fixes. iOS has
/// already made that decision with better information, so handing it over as a typed event
/// removes minutes of latency. The ordinary position POSTs continue unchanged as the slow,
/// never-miss path (agreed with oc-general, 2026-09-13).
@MainActor
enum GeofenceEventReporter {
    /// Wi-Fi leaving / joining, with the network name. Dropping off the home network is
    /// the earliest doorway signal there is, and unlike reading the SSID it works in the
    /// background: the drop itself comes from NWPathMonitor and the name is the one we
    /// last read while on it.
    static func reportWiFi(transition: String, ssid: String?, at occurredAt: Date) {
        let payload = WiFiEventPayload(
            deviceId: AppSettings.shared.deviceId,
            transition: transition,
            ssid: ssid,
            occurredAt: ISO8601DateFormatter.geofence.string(from: occurredAt),
            fixId: UUID().uuidString
        )
        post(payload, label: "wifi_event \(transition) \(ssid ?? "unknown")")
    }

    static func report(anchor: String, transition: String, at occurredAt: Date, accuracy: Double?) {
        let payload = GeofenceEventPayload(
            deviceId: AppSettings.shared.deviceId,
            anchor: anchor,
            transition: transition,
            occurredAt: ISO8601DateFormatter.geofence.string(from: occurredAt),
            accuracyM: accuracy,
            fixId: UUID().uuidString
        )

        post(payload, label: "geofence_event \(anchor) \(transition)")
    }

    private static func post<Payload: Encodable>(_ payload: Payload, label: String) {
        Task { @MainActor in
            var taskId: UIBackgroundTaskIdentifier = .invalid
            taskId = UIApplication.shared.beginBackgroundTask {
                if taskId != .invalid {
                    UIApplication.shared.endBackgroundTask(taskId)
                    taskId = .invalid
                }
            }
            await send(payload, label: label)
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
            }
        }
    }

    private static func send<Payload: Encodable>(_ payload: Payload, label: String) async {
        guard AppSettings.shared.hasValidTelemetryConfig,
              let token = KeychainHelper.shared.getToken(),
              let url = URL(string: "\(AppSettings.shared.telemetryServerURL)/api/telemetry") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await TelemetryService.shared.urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                ActivityLogger.shared.log(.telemetry, "\(label): invalid response")
                return
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                ActivityLogger.shared.log(.telemetry, "\(label): HTTP \(http.statusCode): \(body)")
                return
            }
            ActivityLogger.shared.log(.telemetry, "\(label) sent: HTTP \(http.statusCode)")
        } catch {
            ActivityLogger.shared.log(.telemetry, "\(label) failed: \(error.localizedDescription)")
        }
    }
}

struct GeofenceEventPayload: Encodable {
    let deviceId: String
    let type = "geofence_event"
    let anchor: String
    /// "enter" or "exit".
    let transition: String
    /// When iOS raised the crossing, not when the POST went out — the server needs this
    /// to separate its own latency from the device's.
    let occurredAt: String
    let accuracyM: Double?
    let fixId: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case type
        case anchor
        case transition
        case occurredAt = "occurred_at"
        case accuracyM = "accuracy_m"
        case fixId = "fix_id"
    }
}

struct WiFiEventPayload: Encodable {
    let deviceId: String
    let type = "wifi_event"
    /// "left" or "joined".
    let transition: String
    /// The network involved. nil when iOS never let us read the name.
    let ssid: String?
    let occurredAt: String
    let fixId: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case type
        case transition
        case ssid
        case occurredAt = "occurred_at"
        case fixId = "fix_id"
    }
}

extension ISO8601DateFormatter {
    static let geofence: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
