import CryptoKit
import Foundation

/// Everything recall reads goes to Hub, without choosing. Items of one route are batched
/// into events, because one request per reading would not keep up. Reading them is the
/// consumer's job. A batch leaves memory only once the durable outbox holds it, so a full
/// lane holds items back instead of losing them; a killed process loses what is buffered.
actor HubRawStream {
    static let shared = HubRawStream()

    static let maxItemsPerEvent = 2000
    static let flushDelay: Duration = .seconds(2)

    private struct Pending {
        var items: [Data] = []
        var flushScheduled = false
    }

    private var pending: [HubRecallRoute: Pending] = [:]
    private var lastFailureLogged: [HubRecallRoute: Date] = [:]

    func append<Item: Encodable>(_ item: Item, route: HubRecallRoute) {
        guard let data = try? HubRawEvent.encoder.encode(item) else { return }
        pending[route, default: Pending()].items.append(data)
        if pending[route]?.items.count ?? 0 >= Self.maxItemsPerEvent {
            Task { await flush(route) }
        } else if pending[route]?.flushScheduled == false {
            pending[route]?.flushScheduled = true
            Task {
                try? await Task.sleep(for: Self.flushDelay)
                await flush(route)
            }
        }
    }

    func flush(_ route: HubRecallRoute) async {
        pending[route]?.flushScheduled = false
        while let items = pending[route]?.items, !items.isEmpty {
            let batch = Array(items.prefix(Self.maxItemsPerEvent))
            do {
                _ = try await HubRawEvent.admit(route: route, items: batch, deleted: [], occurredAt: Date())
            } catch {
                noteFailure(route)
                if pending[route]?.flushScheduled == false {
                    pending[route]?.flushScheduled = true
                    Task {
                        try? await Task.sleep(for: Self.flushDelay)
                        await flush(route)
                    }
                }
                return
            }
            // New items may have arrived during the await; they sit behind this batch.
            pending[route]?.items.removeFirst(batch.count)
        }
    }

    private func noteFailure(_ route: HubRecallRoute) {
        let now = Date()
        if let last = lastFailureLogged[route], now.timeIntervalSince(last) < 3600 { return }
        lastFailureLogged[route] = now
        let count = pending[route]?.items.count ?? 0
        Task { @MainActor in
            ActivityLogger.shared.log(.telemetry, "Hub raw \(route.rawValue): admission refused, holding \(count) items")
        }
    }
}

/// One batch event. Its identity covers its content and time, so a batch resent after a
/// crash can never be an immutable conflict: at worst Hub holds it twice, and a reader
/// dedupes health samples by `uuid`.
enum HubRawEvent {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func sourcePayload(items: [Data], deleted: [String]) -> Data {
        var body = Data("{\"deleted\":".utf8)
        body.append((try? JSONSerialization.data(withJSONObject: deleted)) ?? Data("[]".utf8))
        body.append(Data(",\"items\":[".utf8))
        for (index, item) in items.enumerated() {
            if index > 0 { body.append(UInt8(ascii: ",")) }
            body.append(item)
        }
        body.append(Data("]}".utf8))
        return body
    }

    static func observationID(for payload: Data, occurredAt: Date) -> String {
        var input = payload
        input.append(Data("\(occurredAt.timeIntervalSince1970)".utf8))
        return SHA256.hash(data: input).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// nil when the route is not enabled on this device.
    @discardableResult
    static func admit(route: HubRecallRoute, items: [Data], deleted: [String], occurredAt: Date) async throws -> String? {
        guard await HubDeliveryService.shared.isEnabled(route) else { return nil }
        let payload = sourcePayload(items: items, deleted: deleted)
        return try await HubDeliveryService.shared.admit(
            route: route,
            observationID: observationID(for: payload, occurredAt: occurredAt),
            occurredAt: occurredAt,
            timeBasis: "batched_at",
            sourcePayloadJSON: payload
        )
    }
}

struct RawMotionActivity: Encodable {
    let at: Date
    let stationary, walking, running, cycling, automotive, unknown: Bool
    let confidence: Int

    func sameReading(as other: RawMotionActivity?) -> Bool {
        guard let other else { return false }
        return stationary == other.stationary && walking == other.walking && running == other.running
            && cycling == other.cycling && automotive == other.automotive && unknown == other.unknown
            && confidence == other.confidence
    }
}

struct RawStepUpdate: Encodable {
    let start: Date
    let end: Date
    let steps: Int
    let distanceMeters: Double?
    let cadencePerSecond: Double?
    let floorsAscended: Int?
    let floorsDescended: Int?
}

struct RawStepEvent: Encodable {
    let at: Date
    let type: String
}

struct RawBatteryLevel: Encodable {
    let at: Date
    let percent: Int
    let state: String
}

struct RawHealthSample: Encodable {
    let uuid: String
    let type: String
    let start: Date
    let end: Date
    let value: Double?
    let unit: String?
    let valueText: String?
    let source: String?
    let sourceBundleId: String?
    let sourceVersion: String?
    let deviceModel: String?
    let durationSeconds: Double?
}
