import Foundation

/// Small adapter shared by telemetry producers.  It deliberately has no
/// fallback configuration: the Hub service is the sole authority for route
/// enablement and durable admission.
@MainActor
enum HubTelemetryAdmission {
    static func admit<Payload: Encodable>(
        route: HubRecallRoute,
        observationID: String,
        occurredAt: Date,
        timeBasis: String? = nil,
        payload: Payload,
        originalBytes: Data? = nil
    ) async throws -> String? {
        guard HubDeliveryService.shared.isEnabled(route) else { return nil }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let sourcePayloadJSON = try encoder.encode(payload)
        let basis = defaultTimeBasis(for: route)
        return try await HubDeliveryService.shared.admit(
            route: route,
            observationID: observationID,
            occurredAt: occurredAt,
            timeBasis: timeBasis ?? basis,
            sourcePayloadJSON: sourcePayloadJSON,
            originalBytes: originalBytes
        )
    }

    /// The external ID when this observation was already acknowledged with this content (up to
    /// the milliseconds of `occurred_at`), so a re-admission would only measure queue-file drift.
    static func acknowledgedEquivalent<Payload: Encodable>(
        route: HubRecallRoute, observationID: String, occurredAt: Date, payload: Payload,
        allowLostMilliseconds: Bool = false,
        allowRoundedSourceTimestamp: Bool = false
    ) async -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let sourcePayloadJSON = try? encoder.encode(payload) else { return nil }
        return await HubDeliveryService.shared.acknowledgedEquivalent(
            route: route, observationID: observationID, occurredAt: occurredAt,
            timeBasis: defaultTimeBasis(for: route), sourcePayloadJSON: sourcePayloadJSON,
            allowLostMilliseconds: allowLostMilliseconds,
            allowRoundedSourceTimestamp: allowRoundedSourceTimestamp)
    }

    static func defaultTimeBasis(for route: HubRecallRoute) -> String {
        switch route {
        case .gpsDelivery, .nowPlaying: return "timestamp"
        case .healthSnapshot: return "collectedAt"
        case .geofence, .wifi: return "occurred_at"
        case .channelReport: return "sent_at"
        case .audioOriginal: return "chunk_start_utc"
        case .glassesOriginal: return "captured_at"
        }
    }

    static func legacyAllowed(_ route: HubRecallRoute) -> Bool {
        !HubDeliveryService.shared.isEnabled(route) || !HubDeliveryService.shared.legacyDisabled(route)
    }
}
