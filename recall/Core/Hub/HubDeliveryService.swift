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
    private var originalMutations: [HubRecallRoute: UUID] = [:]
    private var audioReservationRecovery: (id: UUID, task: Task<Void, Error>)?
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

    /// Held across source-file creation or source-size snapshot + outbox commit.
    /// Contention is backpressure, never permission to bypass the byte budget.
    func beginOriginalMutation(_ route: HubRecallRoute) -> UUID? {
        guard originalMutations[route] == nil else { return nil }
        let token = UUID()
        originalMutations[route] = token
        return token
    }

    func finishOriginalMutation(_ route: HubRecallRoute, token: UUID) {
        guard originalMutations[route] == token else { return }
        originalMutations.removeValue(forKey: route)
    }

    func admit(route: HubRecallRoute, observationID: String, occurredAt: Date, timeBasis: String,
               sourcePayloadJSON: Data, originalBytes: Data? = nil,
               capture: [String: Any]? = nil) async throws -> String {
        guard isEnabled(route) else { throw Failure.routeDisabled }
        let mutationToken: UUID?
        if route == .glassesOriginal {
            guard let token = beginOriginalMutation(route) else { throw HubDurableOutbox.Failure.laneFull }
            mutationToken = token
        } else { mutationToken = nil }
        defer { if let mutationToken { finishOriginalMutation(route, token: mutationToken) } }
        refreshRuntime()
        guard let configuration, let outbox else { throw Failure.notConfigured }
        if route == .audioOriginal { try await recoverAudioReservations(outbox) }
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
                sourcePayloadJSON: sourcePayloadJSON, originalBytes: originalBytes,
                capture: capture)
            let files = try Self.originalDirectoryBytes(for: route)
            try await outbox.enqueue(envelope, externalOriginalBytes: files)
            return id
        } catch {
            await recordGap(route: route, reason: "admission_failed")
            await recordGap(route: route, reason: Self.admissionRefusalReason(error))
            throw error
        }
    }

    /// The external ID of an observation whose identity already has an acknowledged receipt,
    /// regardless of what body is offered now; nil when it has none (or the outbox cannot be
    /// read). A queued sample whose identity the Hub has already acknowledged is delivered:
    /// re-admitting it only measures how its encoding has drifted since, and the immutable
    /// envelope rightly refuses that. Asking again must not block everything behind it.
    func acknowledgedIdentity(route: HubRecallRoute, observationID: String) async -> String? {
        guard isEnabled(route), let configuration, let outbox,
              let id = try? HubProducerContract.canonicalExternalID(
                route: route, deviceID: configuration.deviceID, observationID: observationID),
              let receipt = try? await outbox.storedReceipt(externalID: id), receipt != nil else { return nil }
        return id
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

    func reserveAudioCapture(token: UUID, bytes: Int64) async throws {
        refreshRuntime()
        guard let outbox else { throw Failure.notConfigured }
        try await recoverAudioReservations(outbox)
        let files = try Self.originalDirectoryBytes(for: .audioOriginal)
        try await outbox.setExternalReservation(lane: "audio-original",
            key: "audio-capture:" + token.uuidString, bytes: bytes, externalOriginalBytes: files)
    }

    private func recoverAudioReservations(_ outbox: HubDurableOutbox) async throws {
        if audioReservationRecovery == nil {
            audioReservationRecovery = (UUID(), Task { try await outbox.recoverAudioCaptureReservations() })
        }
        guard let recovery = audioReservationRecovery else { throw Failure.notConfigured }
        do {
            try await recovery.task.value
        } catch {
            // Only this failed generation may be retried. Success stays cached:
            // a later admission must never clear a live writer's reservation.
            if audioReservationRecovery?.id == recovery.id { audioReservationRecovery = nil }
            throw error
        }
    }

    func releaseAudioCapture(token: UUID) async {
        do {
            guard let outbox else { throw Failure.notConfigured }
            try await outbox.setExternalReservation(lane: "audio-original",
                key: "audio-capture:" + token.uuidString, bytes: 0)
        } catch { await recordGap(route: .audioOriginal, reason: "capture_reservation_release_failed") }
    }

    /// A fixed, bounded vocabulary: the lane being full is not the same fault as the disk
    /// refusing a write, and a diagnostic that says only "failed" hid the difference for days.
    static func admissionRefusalReason(_ error: Error) -> String {
        switch error as? HubDurableOutbox.Failure {
        case .laneFull?: return "admission_lane_full"
        case .receiptSlotsFull?: return "admission_ledger_full"
        case .immutableConflict?: return "admission_conflict"
        case .invalidEnvelope?, .invalidBudget?: return "admission_invalid"
        default: return "admission_persistence"
        }
    }

    /// Body-free usage per lane, or nil when the outbox cannot be read. A caller must treat
    /// nil as unknown, never as healthy.
    func usageSnapshot() async -> [HubDurableOutbox.LaneUsage]? {
        guard let outbox else { return nil }
        return try? await outbox.usage()
    }

    nonisolated enum UsageTransition: Equatable { case becameHigh, recovered }

    /// Hysteresis: warn once on the way up at 80%, once on the way back under 70%.
    nonisolated static func usageTransition(wasHigh: Bool, ratio: Double) -> UsageTransition? {
        if !wasHigh, ratio >= highUsageThreshold { return .becameHigh }
        if wasHigh, ratio < recoveredUsageThreshold { return .recovered }
        return nil
    }

    private var lastUsageCheck = Date.distantPast
    nonisolated private static let highUsageThreshold = 0.8
    nonisolated private static let recoveredUsageThreshold = 0.7

    /// Records one gap when a lane crosses 80% of its budget and one when it falls back under
    /// 70%, so a lane filling up is visible before it refuses anything and does not repeat
    /// every minute while it stays high.
    func evaluateUsageTransitions() async {
        guard Date().timeIntervalSince(lastUsageCheck) >= 60 else { return }
        lastUsageCheck = Date()
        guard let usage = await usageSnapshot() else { return }
        let defaults = UserDefaults.standard
        let tracker = UsageGapTracker(
            isHigh: { defaults.bool(forKey: "hub.usage.gap." + $0) },
            setHigh: { defaults.set($1, forKey: "hub.usage.gap." + $0) },
            record: { await self.recordLaneGap(lane: $0, reason: $1) })
        for lane in usage {
            // The alert (what the status reports) follows the lane at once; the gap record is
            // retried on the next evaluation until it has actually been written.
            let alertKey = "hub.usage.alert." + lane.lane
            let wasAlert = defaults.bool(forKey: alertKey)
            switch Self.usageTransition(wasHigh: wasAlert, ratio: lane.ratio) {
            case .becameHigh?: defaults.set(true, forKey: alertKey)
            case .recovered?: defaults.set(false, forKey: alertKey)
            case nil: break
            }
            await tracker.apply(lane: lane.lane, ratio: lane.ratio)
        }
    }

    /// Lanes currently over the alert threshold (80%, back under at 70%), by name.
    func alertLanes(_ lanes: [String]) -> [String] {
        lanes.filter { UserDefaults.standard.bool(forKey: "hub.usage.alert." + $0) }.sorted()
    }

    private func recordLaneGap(lane: String, reason: String) async -> Bool {
        do {
            guard let outbox else { throw Failure.notConfigured }
            try await outbox.recordGap(lane: lane, reason: reason)
            report("Hub lane \(lane): \(reason)")
            return true
        } catch {
            report("Hub lane \(lane): durable write failed; \(reason) NOT persisted")
            return false
        }
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
        Task { await self.evaluateUsageTransitions() }
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

/// Records the 80% / 70% crossings as gaps. The remembered state moves only after the gap was
/// really written, so a write that failed once is attempted again at the next evaluation
/// instead of being forgotten for as long as the lane stays high.
struct UsageGapTracker {
    var isHigh: (String) -> Bool
    var setHigh: (String, Bool) -> Void
    var record: (String, String) async -> Bool

    func apply(lane: String, ratio: Double) async {
        switch HubDeliveryService.usageTransition(wasHigh: isHigh(lane), ratio: ratio) {
        case .becameHigh?:
            if await record(lane, "usage_ge_80") { setHigh(lane, true) }
        case .recovered?:
            if await record(lane, "usage_recovered") { setHigh(lane, false) }
        case nil:
            break
        }
    }
}

/// What the channel status says about the outbox, and when that is worth a send. Steady
/// all-active sends nothing; a lane crossing 80%, an unreadable outbox, and the return to
/// normal must still reach the server, so each is an edge of its own and a non-normal state
/// repeats hourly like a stretch without capture does.
enum OutboxAlert {
    static let normal = "ok"

    static func classify(snapshotAvailable: Bool, alertLanes: [String]) -> String {
        guard snapshotAvailable else { return "unknown" }
        return alertLanes.isEmpty ? normal : "high:" + alertLanes.joined(separator: ",")
    }

    /// `lastSent` is nil until something has been acknowledged; that counts as normal.
    static func isEdge(current: String, lastSent: String?) -> Bool {
        current != (lastSent ?? normal)
    }

    static func needsLevel(current: String) -> Bool { current != normal }
}

