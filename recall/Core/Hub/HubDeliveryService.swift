import Foundation

/// Main-actor coordinator for durable Hub admission and independent lane delivery.
/// It is deliberately store-only: a storage receipt is the only acknowledgement
/// understood here, and audio remains pending until its processing contract exists.
@MainActor
final class HubDeliveryService {
    static let shared = HubDeliveryService()

    enum Failure: Error, Equatable {
        case unavailable
        case notConfigured
        case routeDisabled
        case legacyRouteDisabled
        case admission(HubDurableOutbox.Failure)
    }

    private var outbox: HubDurableOutbox?
    private var transport: HubIngressTransport?
    private var configuration: HubDeviceConfiguration?
    private var workers: [String: Task<Void, Never>] = [:]
    private var started = false

    init() {}

    func start() {
        guard !started else { return }
        started = true
        do {
            let budgets = try Self.makeBudgets()
            let dbURL = try Self.databaseURL()
            outbox = try HubDurableOutbox(url: dbURL, budgets: budgets)
            for lane in budgets.keys { startWorker(for: lane) }
        } catch {
            // Admission remains explicitly unavailable; no legacy fallback.
            outbox = nil; transport = nil
        }
    }

    var isConfigured: Bool { configuration != nil && outbox != nil && transport != nil }

    func isEnabled(_ route: HubRecallRoute) -> Bool {
        HubProvisioning.shared.enabledRoutes.contains(route.rawValue)
    }

    func legacyDisabled(_ route: HubRecallRoute) -> Bool {
        HubProvisioning.shared.legacyDisabledRoutes.contains(route.rawValue)
    }

    func admit(route: HubRecallRoute, observationID: String, occurredAt: Date,
               timeBasis: String, sourcePayloadJSON: Data,
               originalBytes: Data? = nil) async throws -> String {
        guard isEnabled(route) else {
            if legacyDisabled(route) { throw Failure.legacyRouteDisabled }
            throw Failure.routeDisabled
        }
        refreshRuntime()
        guard let configuration, let outbox else { throw Failure.notConfigured }
        let envelope = try HubProducerContract.makeEnvelope(
            route: route, deviceID: configuration.deviceID, observationID: observationID,
            occurredAt: occurredAt, timeBasis: timeBasis, sourcePayloadJSON: sourcePayloadJSON,
            originalBytes: originalBytes)
        do { try await outbox.enqueue(envelope) }
        catch let error as HubDurableOutbox.Failure { throw Failure.admission(error) }
        return envelope.externalID
    }

    func isAcknowledged(externalID: String) async throws -> Bool {
        guard let outbox else { throw Failure.notConfigured }
        return try await outbox.storedReceipt(externalID: externalID) != nil
    }

    private func startWorker(for lane: String) {
        guard workers[lane] == nil else { return }
        workers[lane] = Task { [weak self] in
            while !Task.isCancelled {
                let delivered = await self?.reconcile(lane: lane) ?? false
                try? await Task.sleep(for: .seconds(delivered ? 1 : 5))
            }
        }
    }

    private func reconcile(lane: String) async -> Bool {
        refreshRuntime()
        guard let outbox, let transport else { return false }
        do {
            guard let lease = try await outbox.leaseNext(lane: lane, duration: 30) else { return false }
            let (status, body) = try await transport.submitRaw(encodedJSON: lease.encodedJSON)
            guard status == 200 || status == 201 else { return false }
            // Audio storage receipts are intentionally not an ACK for processing.
            guard lane != "audio-original" else { return true }
            try await outbox.acknowledge(responseData: body, externalID: lease.externalID)
            return true
        } catch {
            return false
        }
    }

    private func refreshRuntime() {
        guard let value = HubProvisioning.shared.configuration else {
            configuration = nil; transport = nil; return
        }
        guard configuration?.endpoint != value.endpoint || transport == nil else { return }
        do {
            transport = try HubIngressTransport(baseURL: value.endpoint, bearerToken: value.bearerToken)
            configuration = value
        } catch {
            configuration = value; transport = nil
        }
    }

    private static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let dir = root.appendingPathComponent("recall", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("hub-outbox.sqlite")
    }

    private static func makeBudgets() throws -> [String: HubDurableOutbox.LaneBudget] {
        let mib: Int64 = 1024 * 1024
        return [
            "metadata-gps": try .init(maxBytes: 32 * mib, maxItems: .max, maxTombstones: 4096, maxOriginalBytes: 0),
            "metadata-health": try .init(maxBytes: 64 * mib, maxItems: .max, maxTombstones: 4096, maxOriginalBytes: 0),
            "metadata-status": try .init(maxBytes: 32 * mib, maxItems: .max, maxTombstones: 4096, maxOriginalBytes: 0),
            // OriginalCapacity owns source-file accounting; do not charge those bytes again in the outbox.
            "glasses-original": try .init(maxBytes: .max / 4, maxItems: .max, maxTombstones: 4096, maxOriginalBytes: .max),
            "audio-original": try .init(maxBytes: .max / 4, maxItems: .max, maxTombstones: 4096, maxOriginalBytes: .max),
            "control": try .init(maxBytes: 16 * mib, maxItems: .max, maxTombstones: 4096, maxOriginalBytes: 0)
        ]
    }
}
