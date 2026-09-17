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
    /// The audio health class the server last acknowledged. Kept apart from the per-channel
    /// state so a failed send is retried on the next tick rather than lost.
    private var lastSentAudioClass: String?
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

        let sendEdge = changed || (firstRun && anyGated) || audioEdge

        // A stretch without capture repeats itself hourly, like a gated channel does. An
        // edge alone is not enough: the server stops trusting a state it has not heard for
        // two hours, and an outage that outlasts that would otherwise go quiet again.
        let needsLevel = anyGated || audio.healthClass != "capturing"

        var sendLevel = false
        if needsLevel {
            let last = defaults.object(forKey: lastLevelKey) as? Date
            if last == nil || now.timeIntervalSince(last!) >= levelInterval {
                sendLevel = true
            }
        }

        guard sendEdge || sendLevel else { return }

        let ok = await send(entries: entries, sentAt: nowISO, audio: audio)
        if ok { lastSentAudioClass = audio.healthClass }
        // Reset the hourly clock only on a successful send that needed repeating, so a
        // failed send stays retried by the next tick.
        if ok && needsLevel {
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
            activationBlocked: engine?.isActivationBlocked ?? false
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

    private func send(entries: [ChannelEntry], sentAt: String, audio: AudioSnapshot) async -> Bool {
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
            channels: entries,
            audioState: audio.state,
            audioStateSince: audio.since,
            lastChunkAt: audio.lastChunkAt
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
            ActivityLogger.shared.log(.telemetry, "channel_status sent: HTTP \(http.statusCode) audio=\(audio.state) since=\(audio.since)")
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
    /// See `AudioStateSignal`. The server alarms on `blocked:*` / `stopped:internal`
    /// lasting 10 minutes and treats `stopped:user` as information.
    let audioState: String
    let audioStateSince: String
    /// When a chunk was last opened. nil only before the first one ever.
    let lastChunkAt: String?

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case type
        case sentAt = "sent_at"
        case channels
        case audioState = "audio_state"
        case audioStateSince = "audio_state_since"
        case lastChunkAt = "last_chunk_at"
    }
}

private struct ChannelEntry: Encodable {
    let channel: String
    let state: String
    let since: String
}
