import Foundation
import Observation

/// Reports a per-channel "channel_status" heartbeat so the server can distinguish
/// a stream the user intentionally toggled off (`gated_by_user`) from a device/app
/// that has gone dark. This carries NO coordinates and NO health values — only the
/// on/off intent of each top-page toggle and the timestamp it last flipped.
///
/// Send policy:
///   - EDGE:  immediately when any channel's state changes.
///   - LEVEL: once per hour while at least one channel is gated_by_user.
///   - Steady all-active: send nothing.
///
/// Failures are logged and dropped — the next 60s tick is the retry (no queue).
@Observable
@MainActor
final class ChannelStatusReporter {
    static let shared = ChannelStatusReporter()

    private enum ChannelState: String {
        case active
        case gatedByUser = "gated_by_user"
    }

    /// CaseIterable order defines the payload channel order (contract-fixed).
    private enum Channel: String, CaseIterable {
        case audio, location, health, glasses, media
    }

    private let lastLevelKey = "channelStatus.lastLevelSentAt"
    private let levelInterval: TimeInterval = 3600
    private let tickInterval: TimeInterval = 60

    private var loopTask: Task<Void, Never>?

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(self?.tickInterval ?? 60))
            }
        }
    }

    // MARK: - Snapshot (read-only state sources)

    private func currentState(_ channel: Channel) -> ChannelState {
        let telemetry = TelemetryService.shared
        switch channel {
        case .audio:
            // Durable App Group state driven by the Audio toggle / widget.
            let rec = RecordingStateManager.shared
            return (rec.isRecording && !rec.userStopIntent) ? .active : .gatedByUser
        case .location:
            return telemetry.locationManager.isEnabled ? .active : .gatedByUser
        case .health:
            return telemetry.healthManager.isEnabled ? .active : .gatedByUser
        case .glasses:
            return telemetry.glassesHandoffReceiver.isEnabled ? .active : .gatedByUser
        case .media:
            return telemetry.nowPlayingManager.isEnabled ? .active : .gatedByUser
        }
    }

    // MARK: - Tick

    private func tick() async {
        let now = Date()
        let nowISO = Self.iso.string(from: now)
        let defaults = UserDefaults.standard

        var changed = false
        var firstRun = false
        var anyGated = false
        var entries: [ChannelEntry] = []

        for channel in Channel.allCases {
            let current = currentState(channel)
            if current == .gatedByUser { anyGated = true }

            let stateKey = "channelState.\(channel.rawValue)"
            let sinceKey = "channelSince.\(channel.rawValue)"
            let stored = defaults.string(forKey: stateKey)

            if stored == nil {
                // First observation of this channel: seed `since` = now.
                firstRun = true
                if defaults.string(forKey: sinceKey) == nil {
                    defaults.set(nowISO, forKey: sinceKey)
                }
            } else if stored != current.rawValue {
                // State flipped: stamp a fresh `since`.
                changed = true
                defaults.set(nowISO, forKey: sinceKey)
            }
            defaults.set(current.rawValue, forKey: stateKey)

            let since = defaults.string(forKey: sinceKey) ?? nowISO
            entries.append(ChannelEntry(channel: channel.rawValue, state: current.rawValue, since: since))
        }

        let sendEdge = changed || (firstRun && anyGated)

        var sendLevel = false
        if anyGated {
            let last = defaults.object(forKey: lastLevelKey) as? Date
            if last == nil || now.timeIntervalSince(last!) >= levelInterval {
                sendLevel = true
            }
        }

        guard sendEdge || sendLevel else { return }

        let ok = await send(entries: entries, sentAt: nowISO)
        // Reset the hourly clock only on a successful send that included a gated
        // channel, so a failed send stays retried by the next tick.
        if ok && anyGated {
            defaults.set(now, forKey: lastLevelKey)
        }
    }

    // MARK: - Send (reuses the immediate-telemetry auth path)

    private func send(entries: [ChannelEntry], sentAt: String) async -> Bool {
        guard AppSettings.shared.hasValidTelemetryConfig,
              let token = KeychainHelper.shared.getToken() else { return false }

        let serverURL = AppSettings.shared.telemetryServerURL
        guard let url = URL(string: "\(serverURL)/api/telemetry") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")

        let payload = ChannelStatusPayload(
            deviceId: AppSettings.shared.deviceId,
            sentAt: sentAt,
            channels: entries
        )

        do {
            request.httpBody = try JSONEncoder().encode(payload)
            let (data, response) = try await TelemetryService.shared.urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                ActivityLogger.shared.log(.telemetry, "channel_status: invalid response")
                return false
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                ActivityLogger.shared.log(.telemetry, "channel_status: HTTP \(http.statusCode): \(body)")
                return false
            }
            ActivityLogger.shared.log(.telemetry, "channel_status sent: HTTP \(http.statusCode)")
            return true
        } catch {
            ActivityLogger.shared.log(.telemetry, "channel_status send failed: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Payload

private struct ChannelStatusPayload: Encodable {
    let deviceId: String
    let type = "channel_status"
    let sentAt: String
    let channels: [ChannelEntry]

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case type
        case sentAt = "sent_at"
        case channels
    }
}

private struct ChannelEntry: Encodable {
    let channel: String
    let state: String
    let since: String
}
