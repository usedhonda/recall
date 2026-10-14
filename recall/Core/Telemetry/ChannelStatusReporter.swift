import Foundation
import Observation

/// Reports a per-channel "channel_status" heartbeat so the server can distinguish
/// a stream the user intentionally toggled off (`gated_by_user`) from a device/app
/// that has gone dark. This carries NO coordinates and NO health values — only the
/// on/off intent of each top-page toggle and the timestamp it last flipped.
///
/// Send policy:
///   - EDGE:  immediately when any channel's state changes.
///   - LEVEL: once per hour, always. The capacity diagnostic must keep arriving while all is
///     normal, otherwise the server cannot tell a quiet healthy device from a silent one. The
///     first tick sends when no acknowledged-level time is stored; otherwise the next level is
///     due within an hour of the last acknowledged one (the time persists in UserDefaults).
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
    /// The audio health class the server last acknowledged. Kept apart from the per-channel
    /// state so a failed send is retried on the next tick rather than lost.
    private var lastSentAudioClass: String?
    /// The outbox class of the payload the server last acknowledged (see `OutboxAlert`).
    private var lastSentOutboxClass: String?
    private let audioClassKey = "audioState.class"
    private let audioSinceKey = "audioState.since"

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

        let audio = currentAudioState(nowISO: nowISO)
        let audioEdge = audio.healthClass != lastSentAudioClass

        // Without this the steady all-active state sends nothing, and a lane filling up
        // would be recorded locally and never reported.
        await HubDeliveryService.shared.evaluateUsageTransitions()
        let usage = await HubDeliveryService.shared.usageSnapshot()
        let outboxClass = OutboxAlert.classify(
            snapshotAvailable: usage != nil,
            alertLanes: HubDeliveryService.shared.alertLanes(usage?.map(\.lane) ?? []))
        let outboxEdge = OutboxAlert.isEdge(current: outboxClass, lastSent: lastSentOutboxClass)

        let sendEdge = changed || (firstRun && anyGated) || audioEdge || outboxEdge

        // The level repeats hourly in every state: the outbox capacity diagnostic has to keep
        // arriving while everything is normal, or silence cannot be told from health. An edge
        // alone is not enough, the server stops trusting a state it has not heard for two hours.
        let last = defaults.object(forKey: lastLevelKey) as? Date
        let sendLevel = OutboxAlert.levelDue(lastAcknowledgedAt: last, now: now, interval: levelInterval)

        guard sendEdge || sendLevel else { return }

        let ok = await send(entries: entries, sentAt: nowISO, audio: audio, usage: usage, outboxClass: outboxClass)
        // Reset the hourly clock only on a successful send, so a failed send is retried by
        // the next tick.
        if ok {
            defaults.set(now, forKey: lastLevelKey)
        }
    }

    // MARK: - Audio state

    private struct AudioSnapshot {
        let state: String
        let healthClass: String
        let since: String
        let lastChunkAt: String?
    }

    /// Whether the microphone is actually capturing, and since when. The per-channel entry
    /// only says whether the owner's switch is on; this says whether that switch is being
    /// honoured. See `AudioStateSignal`.
    private func currentAudioState(nowISO: String) -> AudioSnapshot {
        let rec = RecordingStateManager.shared
        let engine = RecordingViewModel.shared.engine
        let engineState: AudioStateSignal.Engine
        switch engine?.state {
        case nil: engineState = .none
        case .idle: engineState = .idle
        case .listening: engineState = .listening
        case .recording: engineState = .recording
        case .paused: engineState = .paused
        }
        let state = AudioStateSignal.describe(
            toggleOn: rec.isRecording && !rec.userStopIntent,
            engine: engineState,
            blockReason: engine?.activationBlockReason
        )
        let healthClass = AudioStateSignal.healthClass(of: state)

        let defaults = UserDefaults.standard
        if defaults.string(forKey: audioClassKey) != healthClass {
            defaults.set(healthClass, forKey: audioClassKey)
            defaults.set(nowISO, forKey: audioSinceKey)
        }
        let lastChunk = (defaults.object(forKey: AudioStateSignal.lastChunkKey) as? Date)
            .map { Self.iso.string(from: $0) }

        return AudioSnapshot(
            state: state,
            healthClass: healthClass,
            since: defaults.string(forKey: audioSinceKey) ?? nowISO,
            lastChunkAt: lastChunk
        )
    }

    // MARK: - Send (reuses the immediate-telemetry auth path)

    private func send(entries: [ChannelEntry], sentAt: String, audio: AudioSnapshot,
                      usage: [HubDurableOutbox.LaneUsage]?, outboxClass: String) async -> Bool {
        let currentPayload = ChannelStatusPayload(
            deviceId: AppSettings.shared.deviceId,
            sentAt: sentAt,
            channels: entries,
            audioState: audio.state,
            audioStateSince: audio.since,
            lastChunkAt: audio.lastChunkAt,
            hubOutboxState: usage == nil ? "unknown" : "ok",
            hubOutboxClass: outboxClass,
            hubOutbox: usage?.map { lane in
                OutboxLaneEntry(
                    lane: lane.lane, pendingCount: lane.pendingCount, pendingBytes: lane.pendingBytes,
                    acknowledgedCount: lane.acknowledgedCount, acknowledgedBytes: lane.acknowledgedBytes,
                    reservedBytes: lane.reservedBytes, capBytes: lane.capBytes,
                    lastReceiptAt: lane.lastReceiptAt.map { Self.iso.string(from: $0) },
                    lastRejection: lane.lastRejectionReason,
                    lastRejectionAt: lane.lastRejectionAt.map { Self.iso.string(from: $0) },
                    rejections: lane.rejectionCount)
            }
        )

        var payload = currentPayload
        do {
            let defaults = UserDefaults.standard
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            if let pending = defaults.string(forKey: "hub.channel.pending.payload"),
               let pendingData = Data(base64Encoded: pending),
               let decoded = try? JSONDecoder().decode(ChannelStatusPayload.self, from: pendingData) {
                payload = decoded
            } else {
                payload = currentPayload
                defaults.set((try encoder.encode(payload)).base64EncodedString(), forKey: "hub.channel.pending.payload")
                defaults.set(UUID().uuidString, forKey: "hub.channel.pending.id")
            }
            let id = defaults.string(forKey: "hub.channel.pending.id") ?? UUID().uuidString
            if defaults.string(forKey: "hub.channel.pending.id") == nil { defaults.set(id, forKey: "hub.channel.pending.id") }
            guard let sourceTime = ChannelStatusSourceClock.date(from: payload.sentAt) else {
                await HubDeliveryService.shared.recordGap(route: .channelReport, reason: "invalid_source_clock")
                return false
            }
            if let externalID = try await HubTelemetryAdmission.admit(route: .channelReport, observationID: id,
                                                                       occurredAt: sourceTime, payload: payload),
               !HubTelemetryAdmission.legacyAllowed(.channelReport) {
                guard try await HubDeliveryService.shared.isAcknowledged(externalID: externalID) else { return false }
                defaults.removeObject(forKey: "hub.channel.pending.fingerprint")
                defaults.removeObject(forKey: "hub.channel.pending.payload")
                defaults.removeObject(forKey: "hub.channel.pending.id")
                lastSentAudioClass = AudioStateSignal.healthClass(of: payload.audioState)
                lastSentOutboxClass = payload.hubOutboxClass ?? OutboxAlert.normal
                return true
            }
        } catch {
            ActivityLogger.shared.log(.telemetry, "channel_status Hub admission failed")
            return false
        }

        guard AppSettings.shared.hasValidTelemetryConfig,
              let token = KeychainHelper.shared.getToken() else { return false }

        let serverURL = AppSettings.shared.telemetryServerURL
        guard let url = URL(string: "\(serverURL)/api/telemetry") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")

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
            ActivityLogger.shared.log(.telemetry, "channel_status sent: HTTP \(http.statusCode) audio=\(audio.state) since=\(audio.since)")
            UserDefaults.standard.removeObject(forKey: "hub.channel.pending.fingerprint")
            UserDefaults.standard.removeObject(forKey: "hub.channel.pending.payload")
            UserDefaults.standard.removeObject(forKey: "hub.channel.pending.id")
            lastSentAudioClass = AudioStateSignal.healthClass(of: payload.audioState)
                lastSentOutboxClass = payload.hubOutboxClass ?? OutboxAlert.normal
            return true
        } catch {
            ActivityLogger.shared.log(.telemetry, "channel_status send failed: \(error.localizedDescription)")
            return false
        }
    }
}

/// Parses source timestamps emitted by this reporter and retained pending payloads.
///
/// `ISO8601DateFormatter` with `.withInternetDateTime` (used by `Self.iso`) omits
/// fractional seconds, while pending payloads may have been encoded with them. Keep
/// both wire forms valid without changing the send policy.
internal enum ChannelStatusSourceClock {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecond: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(from sourceTime: String) -> Date? {
        fractional.date(from: sourceTime) ?? wholeSecond.date(from: sourceTime)
    }
}

// MARK: - Payload

private struct ChannelStatusPayload: Codable {
    let deviceId: String
    let type = "channel_status"
    let sentAt: String
    let channels: [ChannelEntry]
    /// See `AudioStateSignal`. The server alarms on `blocked:*` / `stopped:internal`
    /// lasting 10 minutes and treats `stopped:user` as information.
    let audioState: String
    let audioStateSince: String
    /// When a chunk was last opened. nil only before the first one ever.
    let lastChunkAt: String?
    /// Body-free state of the durable outbox, lane by lane. `hubOutboxState` is "ok" when the
    /// lanes could be read and "unknown" when they could not; unknown is never healthy.
    let hubOutboxState: String?
    /// `OutboxAlert` class of this payload; what the reporter marks as delivered, so an older
    /// pending payload being acknowledged never counts as having reported a newer state.
    let hubOutboxClass: String?
    let hubOutbox: [OutboxLaneEntry]?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case type
        case sentAt = "sent_at"
        case channels
        case audioState = "audio_state"
        case audioStateSince = "audio_state_since"
        case lastChunkAt = "last_chunk_at"
        case hubOutboxState = "hub_outbox_state"
        case hubOutboxClass = "hub_outbox_class"
        case hubOutbox = "hub_outbox"
    }
}

private struct OutboxLaneEntry: Codable {
    let lane: String
    let pendingCount: Int64
    let pendingBytes: Int64
    let acknowledgedCount: Int64
    let acknowledgedBytes: Int64
    let reservedBytes: Int64
    let capBytes: Int64
    let lastReceiptAt: String?
    let lastRejection: String?
    let lastRejectionAt: String?
    let rejections: Int64

    enum CodingKeys: String, CodingKey {
        case lane
        case pendingCount = "pending_count"
        case pendingBytes = "pending_bytes"
        case acknowledgedCount = "acknowledged_count"
        case acknowledgedBytes = "acknowledged_bytes"
        case reservedBytes = "reserved_bytes"
        case capBytes = "cap_bytes"
        case lastReceiptAt = "last_receipt_at"
        case lastRejection = "last_rejection"
        case lastRejectionAt = "last_rejection_at"
        case rejections
    }
}

private struct ChannelEntry: Codable {
    let channel: String
    let state: String
    let since: String
}
