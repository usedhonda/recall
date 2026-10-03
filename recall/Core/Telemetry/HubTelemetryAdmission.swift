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
        let basis: String
        switch route {
        case .gpsDelivery, .nowPlaying: basis = "timestamp"
        case .healthSnapshot: basis = "collectedAt"
        case .geofence, .wifi: basis = "occurred_at"
        case .channelReport: basis = "sent_at"
        case .audioOriginal: basis = "chunk_start_utc"
        case .glassesOriginal: basis = "captured_at"
        }
        return try await HubDeliveryService.shared.admit(
            route: route,
            observationID: observationID,
            occurredAt: occurredAt,
            timeBasis: timeBasis ?? basis,
            sourcePayloadJSON: sourcePayloadJSON,
            originalBytes: originalBytes
        )
    }

    static func legacyAllowed(_ route: HubRecallRoute) -> Bool {
        !HubDeliveryService.shared.isEnabled(route) || !HubDeliveryService.shared.legacyDisabled(route)
    }
}
