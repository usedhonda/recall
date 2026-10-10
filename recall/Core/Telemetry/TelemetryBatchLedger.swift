import Foundation

/// Durable ownership for URLSession telemetry batches. Scheduling a task is not
/// delivery: a row remains pending until its callback validates the response.
actor TelemetryBatchLedger {
    enum Failure: Error { case requestFileMissing, storageUnreadable }
    enum State: String, Codable { case pending, delivered }
    struct Batch: Codable, Identifiable {
        let id: UUID
        let sampleIDs: [UUID]
        let healthIncluded: Bool
        let healthDeliveryID: String?
        var locationDelivered: Bool
        var healthDelivered: Bool
        let healthFingerprint: String?
        let healthCollectedAt: Date?
        let requestFilePath: String
        let createdAt: Date
        var taskDescription: String?
        var state: State

        init(id: UUID, sampleIDs: [UUID], healthIncluded: Bool, healthDeliveryID: String?,
             locationDelivered: Bool, healthDelivered: Bool, healthFingerprint: String?, healthCollectedAt: Date?,
             requestFilePath: String, createdAt: Date, taskDescription: String?, state: State) {
            self.id = id; self.sampleIDs = sampleIDs; self.healthIncluded = healthIncluded
            self.healthDeliveryID = healthDeliveryID; self.locationDelivered = locationDelivered; self.healthDelivered = healthDelivered
            self.healthFingerprint = healthFingerprint; self.healthCollectedAt = healthCollectedAt
            self.requestFilePath = requestFilePath; self.createdAt = createdAt; self.taskDescription = taskDescription; self.state = state
        }

        enum CodingKeys: String, CodingKey { case id, sampleIDs, healthIncluded, healthDeliveryID, locationDelivered, healthDelivered, healthFingerprint, healthCollectedAt, requestFilePath, createdAt, taskDescription, state }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id); sampleIDs = try c.decode([UUID].self, forKey: .sampleIDs)
            healthIncluded = try c.decode(Bool.self, forKey: .healthIncluded)
            healthDeliveryID = try c.decodeIfPresent(String.self, forKey: .healthDeliveryID)
            locationDelivered = try c.decodeIfPresent(Bool.self, forKey: .locationDelivered) ?? sampleIDs.isEmpty
            healthDelivered = try c.decodeIfPresent(Bool.self, forKey: .healthDelivered) ?? !healthIncluded
            healthFingerprint = try c.decodeIfPresent(String.self, forKey: .healthFingerprint)
            healthCollectedAt = try c.decodeIfPresent(Date.self, forKey: .healthCollectedAt)
            requestFilePath = try c.decode(String.self, forKey: .requestFilePath); createdAt = try c.decode(Date.self, forKey: .createdAt)
            taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription); state = try c.decode(State.self, forKey: .state)
        }
    }

    static let shared = TelemetryBatchLedger()
    private let url: URL
    private var rows: [UUID: Batch]
    private var healthy = true

    init(url: URL? = nil) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.url = url ?? documents.appendingPathComponent("recall_telemetry_batches.json")
        if let data = try? Data(contentsOf: self.url),
           let decoded = try? JSONDecoder.telemetry.decode([UUID: Batch].self, from: data) {
            self.rows = decoded
        } else {
            self.rows = [:]
            self.healthy = !FileManager.default.fileExists(atPath: self.url.path)
        }
    }

    func create(id: UUID = UUID(), sampleIDs: [UUID], healthIncluded: Bool, healthDeliveryID: String? = nil,
                healthFingerprint: String? = nil, healthCollectedAt: Date? = nil,
                requestFile: URL) throws -> Batch {
        let batch = Batch(id: id, sampleIDs: sampleIDs, healthIncluded: healthIncluded,
                          healthDeliveryID: healthDeliveryID,
                          locationDelivered: sampleIDs.isEmpty,
                          healthDelivered: !healthIncluded,
                          healthFingerprint: healthFingerprint,
                          healthCollectedAt: healthCollectedAt,
                          requestFilePath: requestFile.path, createdAt: Date(),
                          taskDescription: nil, state: .pending)
        var proposed = rows; proposed[batch.id] = batch
        try persist(proposed)
        rows = proposed
        return batch
    }

    func setTaskDescription(_ description: String, for id: UUID) throws {
        guard var row = rows[id] else { return }
        row.taskDescription = description
        var proposed = rows; proposed[id] = row
        try persist(proposed); rows = proposed
    }

    func pending() -> [Batch] { rows.values.filter { $0.state == .pending } }
    func hasPending(sampleIDs: [UUID], healthIncluded: Bool) -> Bool {
        let wanted = Set(sampleIDs)
        return rows.values.contains { $0.state == .pending && $0.healthIncluded == healthIncluded && Set($0.sampleIDs) == wanted }
    }
    func pendingBatch(sampleIDs: [UUID], healthIncluded: Bool) -> Batch? {
        let wanted = Set(sampleIDs)
        return rows.values.first { $0.state == .pending && $0.healthIncluded == healthIncluded && Set($0.sampleIDs) == wanted }
    }
    func pendingHealth(deliveryID: String) -> Batch? {
        rows.values.first { $0.state == .pending && $0.sampleIDs.isEmpty && $0.healthDeliveryID == deliveryID }
    }
    func hasPendingOverlap(sampleIDs: [UUID]) -> Bool {
        let wanted = Set(sampleIDs)
        return rows.values.contains { $0.state == .pending && !wanted.isDisjoint(with: $0.sampleIDs) }
    }
    func batch(id: UUID) -> Batch? { rows[id] }
    func batch(forTaskDescription value: String) -> Batch? {
        rows.values.first { $0.taskDescription == value && $0.state == .pending }
    }

    func markDelivered(_ id: UUID) throws -> Batch? {
        guard var row = rows[id], row.state == .pending else { return nil }
        row.state = .delivered
        var proposed = rows; proposed[id] = row
        let delivered = proposed.values.filter { $0.state == .delivered }.sorted { $0.createdAt < $1.createdAt }
        if delivered.count > 64 {
            for old in delivered.prefix(delivered.count - 64) { proposed.removeValue(forKey: old.id) }
        }
        try persist(proposed); rows = proposed
        try? FileManager.default.removeItem(at: requestURL(row))
        return row
    }

    func recordOutcome(_ id: UUID, location: Bool, health: Bool) throws -> Batch? {
        guard var row = rows[id], row.state == .pending else { return nil }
        row.locationDelivered = row.locationDelivered || location
        row.healthDelivered = row.healthDelivered || health
        let complete = row.locationDelivered && row.healthDelivered
        if complete { row.state = .delivered }
        var proposed = rows; proposed[id] = row
        if complete {
            let delivered = proposed.values.filter { $0.state == .delivered }.sorted { $0.createdAt < $1.createdAt }
            if delivered.count > 64 { for old in delivered.prefix(delivered.count - 64) { proposed.removeValue(forKey: old.id) } }
        }
        try persist(proposed); rows = proposed
        if complete { try? FileManager.default.removeItem(at: requestURL(row)) }
        return row
    }

    /// Missing/cancelled URLSession tasks are made retryable while retaining the
    /// original body and sample IDs. The next drain may schedule that exact row.
    func clearTaskDescription(_ id: UUID) throws {
        guard var row = rows[id], row.state == .pending else { return }
        row.taskDescription = nil
        var proposed = rows; proposed[id] = row
        try persist(proposed); rows = proposed
    }

    func ensureRequestFile(for row: Batch) throws -> URL {
        let file = requestURL(row)
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure.requestFileMissing }
        return file
    }

    func discard(_ id: UUID) throws {
        guard let row = rows[id], row.state == .pending else { return }
        var proposed = rows; proposed.removeValue(forKey: id)
        try persist(proposed); rows = proposed
        try? FileManager.default.removeItem(at: requestURL(row))
    }

    private func requestURL(_ row: Batch) -> URL {
        // App container roots may change after an install; the fixed file is beside
        // the ledger, not at a stale absolute container path.
        url.deletingLastPathComponent().appendingPathComponent(URL(fileURLWithPath: row.requestFilePath).lastPathComponent)
    }

    private func persist(_ value: [UUID: Batch]) throws {
        guard healthy else { throw Failure.storageUnreadable }
        let encoder = JSONEncoder.telemetry
        try encoder.encode(value).write(to: url, options: .atomic)
    }

}

private extension JSONEncoder {
    static var telemetry: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
private extension JSONDecoder {
    static var telemetry: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
