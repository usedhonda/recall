import Foundation
import CryptoKit

/// Each lane recovers from its own durable queue; credentials never fall back to Gateway.
@MainActor
final class HubDeliveryService {
    static let shared = HubDeliveryService()
    enum Failure: Error { case notConfigured, routeDisabled, immutableOriginalConflict }
    private var outbox: HubDurableOutbox?
    private var transport: HubIngressTransport?
    private var configuration: HubDeviceConfiguration?
    private var workers: [String: Task<Void, Never>] = [:]
    private var lastRefresh = Date.distantPast
    private var lastReported: [String: Date] = [:]
    private(set) var lastFailure: String?

    func start() {
        refreshRuntime()
        for lane in ["metadata-gps", "metadata-health", "metadata-status", "audio-original", "glasses-original"] {
            guard workers[lane] == nil else { continue }
            workers[lane] = Task { [weak self] in
                while !Task.isCancelled {
                    let delivered = await self?.reconcile(lane: lane) ?? false
                    try? await Task.sleep(for: .seconds(delivered ? 0.1 : 5))
                }
            }
        }
    }

    var isConfigured: Bool { configuration != nil && outbox != nil && transport != nil }
    func isEnabled(_ route: HubRecallRoute) -> Bool { HubProvisioning.shared.enabledRoutes.contains(route.rawValue) }
    func legacyDisabled(_ route: HubRecallRoute) -> Bool { HubProvisioning.shared.legacyDisabledRoutes.contains(route.rawValue) }

    func admit(route: HubRecallRoute, observationID: String, occurredAt: Date, timeBasis: String,
               sourcePayloadJSON: Data, originalBytes: Data? = nil) async throws -> String {
        guard isEnabled(route) else { throw Failure.routeDisabled }
        refreshRuntime()
        guard let configuration, let outbox else { throw Failure.notConfigured }
        if route == .gpsDelivery,
           !(await LocationQueue.shared.reconcileHubReservation()) {
            throw Failure.notConfigured
        }
        let id = try HubProducerContract.canonicalExternalID(route: route, deviceID: configuration.deviceID,
                                                             observationID: observationID)
        if originalBytes != nil, try await outbox.contains(externalID: id) {
            // Recover the previously fixed envelope after a producer-row save failure.
            // Never reconstruct retry metadata, but changed original bytes must conflict.
            let hash = originalBytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            guard try await outbox.matchesOriginal(externalID: id, sha256: hash, byteLength: originalBytes?.count ?? 0)
            else { throw Failure.immutableOriginalConflict }
            return id
        }
        do {
            let envelope = try HubProducerContract.makeEnvelope(route: route, deviceID: configuration.deviceID,
                observationID: observationID, occurredAt: occurredAt, timeBasis: timeBasis,
                sourcePayloadJSON: sourcePayloadJSON, originalBytes: originalBytes)
            let files = try Self.originalDirectoryBytes(for: route)
            try await outbox.enqueue(envelope, externalOriginalBytes: files)
            return id
        } catch {
            await recordGap(route: route, reason: "admission_failed")
            throw error
        }
    }

    func isAcknowledged(externalID: String) async throws -> Bool {
        guard let outbox else { throw Failure.notConfigured }
        return try await outbox.storedReceipt(externalID: externalID) != nil
    }

    func retainedBytes(route: HubRecallRoute) async throws -> Int64 {
        refreshRuntime()
        guard let outbox else { throw Failure.notConfigured }
        return try await outbox.retainedBytes(lane: HubDurableOutbox.lane(for: route))
    }

    /// Atomically reserves bytes owned by a source queue in the same Hub DB.
    func reserveQueueBytes(route: HubRecallRoute, key: String, bytes: Int64) async throws {
        refreshRuntime()
        guard let outbox else { throw Failure.notConfigured }
        try await outbox.setExternalReservation(lane: HubDurableOutbox.lane(for: route), key: key, bytes: bytes)
    }

    func recordGap(route: HubRecallRoute, reason: String) async {
        let lane = HubDurableOutbox.lane(for: route)
        do {
            guard let outbox else { throw Failure.notConfigured }
            try await outbox.recordGap(lane: lane, reason: reason)
            report("Hub lane \(lane): \(reason); gap recorded")
        } catch {
            report("Hub lane \(lane): durable write failed; gap NOT persisted")
        }
    }

    private func reconcile(lane: String) async -> Bool {
        refreshRuntime()
        guard let outbox, let transport else { return false }
        let canSend: Bool
        switch lane {
        case "audio-original", "glasses-original": canSend = ConnectivityMonitor.shared.canUploadAudio
        case "metadata-gps": canSend = ConnectivityMonitor.shared.canSendLocation
        case "metadata-health": canSend = ConnectivityMonitor.shared.canSendHealth
        case "metadata-status": canSend = ConnectivityMonitor.shared.canSendLocation
        default: canSend = true
        }
        guard canSend else { return false }
        do {
            guard let lease = try await outbox.leaseNext(lane: lane, duration: 90) else { return false }
            let (status, body) = try await transport.submitRaw(encodedJSON: lease.encodedJSON)
            guard status == 200 || status == 201 else {
                report("Hub lane \(lane): HTTP \(status), retained")
                return false
            }
            try await outbox.acknowledge(responseData: body, externalID: lease.externalID)
            ActivityLogger.shared.log(.upload, "Hub committed receipt verified lane=\(lane)")
            return true
        } catch {
            report("Hub lane \(lane): delivery or receipt failure, retained")
            return false
        }
    }

    private func refreshRuntime() {
        guard Date().timeIntervalSince(lastRefresh) >= 5 else { return }
        lastRefresh = Date()
        do { try HubProvisioning.shared.loadAndImport() }
        catch { report("Hub private configuration unavailable; activation preserved") }
        if outbox == nil {
            do { outbox = try HubDurableOutbox(url: Self.databaseURL(), budgets: Self.makeBudgets()) }
            catch { report("Hub outbox unavailable; durable write failure") }
        }
        guard let value = HubProvisioning.shared.configuration else {
            configuration = nil; transport = nil; return
        }
        if configuration?.endpoint == value.endpoint && configuration?.bearerToken == value.bearerToken && transport != nil {
            configuration = value
            return
        }
        configuration = value
        do { transport = try HubIngressTransport(baseURL: value.endpoint, bearerToken: value.bearerToken) }
        catch { transport = nil; report("Hub transport unavailable") }
    }

    private func report(_ value: String) {
        lastFailure = value
        guard Date().timeIntervalSince(lastReported[value] ?? .distantPast) > 60 else { return }
        lastReported[value] = Date()
        ActivityLogger.shared.log(.error, value)
    }

    private static func databaseURL() throws -> URL {
        let fm = FileManager.default
        let root = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        var dir = root.appendingPathComponent("recall", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
        return dir.appendingPathComponent("hub-outbox.sqlite")
    }

    private static func makeBudgets() throws -> [String: HubDurableOutbox.LaneBudget] {
        let mib: Int64 = 1024 * 1024
        let audio = Int64(AppSettings.shared.storageCapMB) * mib
        return try ["metadata-gps": 32 * mib, "metadata-health": 64 * mib,
                    "metadata-status": 32 * mib, "glasses-original": 512 * mib,
                    "audio-original": audio, "control": 16 * mib].mapValues {
            try .init(maxBytes: $0, maxItems: .max, maxTombstones: .max)
        }
    }

    static func originalDirectoryBytes(for route: HubRecallRoute) throws -> Int64 {
        guard route == .audioOriginal || route == .glassesOriginal else { return 0 }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent(route == .audioOriginal ? "chunks" : "media")
        guard FileManager.default.fileExists(atPath: dir.path) else { return 0 }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) {
            let bytes = try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            return $0 + Int64(bytes)
        }
    }
}
