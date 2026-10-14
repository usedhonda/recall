import CryptoKit
import Foundation
import SQLite3

/// Inactive producer foundation. Explicit lane budgets bound encoded pending
/// bytes and retained receipt slots, not total filesystem/capture staging use.
actor HubDurableOutbox {
    struct LaneBudget: Sendable {
        let maxBytes: Int64
        /// Conservative reservation for physical originals represented by a row.
        /// Metadata rows use zero; audio/glasses rows reserve their original length.
        let maxOriginalBytes: Int64
        let maxItems: Int64
        let maxTombstones: Int64

        init(maxBytes: Int64, maxItems: Int64, maxTombstones: Int64,
             maxOriginalBytes: Int64 = .max) throws {
            guard maxBytes > 0, maxOriginalBytes >= 0, maxItems > 0, maxTombstones > 0 else { throw Failure.invalidBudget }
            self.maxBytes = maxBytes; self.maxOriginalBytes = maxOriginalBytes
            self.maxItems = maxItems
            self.maxTombstones = maxTombstones
        }
    }

    struct Lease: Sendable {
        let externalID: String
        let encodedJSON: Data
        let expectedReceipt: HubExpectedStorageReceipt
        let expiresAt: Date
    }

    enum Failure: Error, Equatable {
        case invalidBudget, invalidEnvelope, invalidLease, laneFull, receiptSlotsFull
        case immutableConflict, notFound, receiptMismatch, corruptRecord
        case storage(Int32)
    }

    private let db: OpaquePointer
    private let budgets: [String: LaneBudget]

    init(url: URL, budgets: [String: LaneBudget]) throws {
        guard !budgets.isEmpty, budgets.keys.allSatisfy({ !$0.isEmpty }) else { throw Failure.invalidBudget }
        self.budgets = budgets
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw Failure.storage(code)
        }
        db = handle
        do {
            sqlite3_busy_timeout(db, 1_000)
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS hub_outbox_v1 (id TEXT PRIMARY KEY, lane TEXT NOT NULL, body BLOB, body_hash TEXT NOT NULL, original_hash TEXT NOT NULL, original_bytes INTEGER NOT NULL, state INTEGER NOT NULL DEFAULT 0, lease_until REAL NOT NULL DEFAULT 0, receipt BLOB, processing_receipt BLOB)")
            try execute("CREATE TABLE IF NOT EXISTS hub_reservations_v1 (lane TEXT NOT NULL, reservation_key TEXT NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY(lane,reservation_key))")
            try migrateProcessingReceiptColumn()
            try ensureColumn("acked_at", type: "REAL")
            try execute("CREATE TABLE IF NOT EXISTS hub_gaps_v1 (lane TEXT NOT NULL, reason TEXT NOT NULL, first_at REAL NOT NULL, last_at REAL NOT NULL, count INTEGER NOT NULL, PRIMARY KEY(lane,reason))")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    /// Same ID and bytes is a retry, including after ACK. Different immutable
    /// bytes conflict. Reserve a receipt slot now so ACK cannot exhaust it later.
    func enqueue(_ envelope: HubProducerEnvelope, externalOriginalBytes: Int64 = 0) throws {
        let lane = lane(for: envelope.route)
        guard let budget = budgets[lane] else { throw Failure.invalidBudget }
        guard envelope.source == "recall", !envelope.externalID.isEmpty,
              !envelope.encodedJSON.isEmpty,
              envelope.encodedJSON.count <= HubProducerContract.maximumEncodedJSONBytes,
              envelope.originalByteLength >= 0 else { throw Failure.invalidEnvelope }
        let hash = Self.digest(envelope.encodedJSON)
        try transaction {
            if let existing = try row(envelope.externalID) {
                guard existing.lane == lane, existing.bodyHash == hash,
                      existing.originalHash == envelope.originalSHA256,
                      existing.originalBytes == envelope.originalByteLength else { throw Failure.immutableConflict }
                return
            }
            // Reserve one SQLite page per retained identity/receipt in addition
            // to actual JSON bytes. ACK cannot consume an unreserved receipt slot.
            let used = try scalar("SELECT COALESCE(SUM(\(Self.retainedCostSQL)),0) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
            let reservations = try scalar("SELECT COALESCE(SUM(bytes),0) FROM hub_reservations_v1 WHERE lane=?", [.text(lane)])
            let pending = try scalar("SELECT COUNT(*) FROM hub_outbox_v1 WHERE lane=? AND state!=2", [.text(lane)])
            let reserved = try scalar("SELECT COUNT(*) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
            let bytes = Int64(envelope.encodedJSON.count) + 4096
            let originalBytes = Int64(envelope.originalByteLength)
            let usedOriginal = try scalar("SELECT COALESCE(SUM(CASE WHEN state!=2 THEN original_bytes ELSE 0 END),0) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
            guard externalOriginalBytes >= 0, externalOriginalBytes <= budget.maxBytes,
                  bytes <= budget.maxBytes - externalOriginalBytes,
                  reservations <= budget.maxBytes - externalOriginalBytes - bytes,
                  used <= budget.maxBytes - externalOriginalBytes - bytes - reservations,
                  originalBytes <= budget.maxOriginalBytes,
                  usedOriginal <= budget.maxOriginalBytes - originalBytes,
                  pending < budget.maxItems else { throw Failure.laneFull }
            guard reserved < budget.maxTombstones else { throw Failure.receiptSlotsFull }
            try execute("INSERT INTO hub_outbox_v1(id,lane,body,body_hash,original_hash,original_bytes) VALUES(?,?,?,?,?,?)",
                [.text(envelope.externalID), .text(lane), .blob(envelope.encodedJSON), .text(hash),
                 .text(envelope.originalSHA256 ?? ""), .int(Int64(envelope.originalByteLength))])
        }
    }

    /// What one retained row costs against its lane budget.
    ///
    /// A row that is not yet acknowledged keeps its body and one SQLite page (4096 B) reserved,
    /// so acknowledging it can never need an unreserved slot. After acknowledgement the body is
    /// gone and only the identity and receipt ledger remains; that is counted at its real byte
    /// size plus a fixed overhead, never above the page it was admitted with. Charging every
    /// acknowledged row a full page overstated each GPS row about nine times and filled the
    /// 32 MiB lane at ~8,192 rows (2026-10-11), rejecting every new position while nothing was
    /// actually near the disk limit. No receipt, identity or history is removed. This is
    /// byte accounting for the lane budget, not a guarantee about free disk space.
    private static let retainedCostSQL = """
        CASE WHEN state=2 AND body IS NULL THEN MIN(4096,
            COALESCE(length(CAST(id AS BLOB)),0) + COALESCE(length(CAST(lane AS BLOB)),0)
            + COALESCE(length(CAST(body_hash AS BLOB)),0) + COALESCE(length(CAST(original_hash AS BLOB)),0)
            + COALESCE(length(CAST(receipt AS BLOB)),0) + COALESCE(length(CAST(processing_receipt AS BLOB)),0)
            + 128)
        ELSE COALESCE(length(body),0) + 4096 END
        """

    static func lane(for route: HubRecallRoute) -> String {
        switch route {
        case .gpsDelivery: return "metadata-gps"
        case .healthSnapshot: return "metadata-health"
        case .geofence, .wifi, .channelReport, .nowPlaying: return "metadata-status"
        case .audioOriginal: return "audio-original"
        case .glassesOriginal: return "glasses-original"
        }
    }

    private func lane(for route: HubRecallRoute) -> String {
        let grouped = Self.lane(for: route)
        return budgets[grouped] != nil ? grouped : route.rawValue
    }

    /// Leasing never removes bytes. Expiry permits another attempt of the exact
    /// same body; separate instances serialize selection/update in one transaction.
    func leaseNext(lane: String, now: Date = Date(), duration: TimeInterval) throws -> Lease? {
        guard budgets[lane] != nil else { throw Failure.invalidBudget }
        let start = now.timeIntervalSince1970
        let end = start + duration
        guard start.isFinite, duration.isFinite, duration > 0, end.isFinite else { throw Failure.invalidLease }
        return try transaction {
            let statement = try prepare("SELECT id FROM hub_outbox_v1 WHERE lane=? AND (state=0 OR (state=1 AND lease_until<=?)) ORDER BY rowid LIMIT 1",
                                        [.text(lane), .double(start)])
            defer { sqlite3_finalize(statement) }
            guard try step(statement) == SQLITE_ROW else { return nil }
            let id = try textColumn(statement, 0)
            guard let record = try row(id), let body = record.body else { throw Failure.corruptRecord }
            try execute("UPDATE hub_outbox_v1 SET state=1, lease_until=? WHERE id=?", [.double(end), .text(id)])
            return Lease(externalID: id, encodedJSON: body, expectedReceipt: record.expected(id),
                         expiresAt: Date(timeIntervalSince1970: end))
        }
    }

    /// The only ACK entry point. Expectations and prior binding come from disk,
    /// not from the caller or server. Body release and receipt persistence commit
    /// atomically, so a crash leaves either a retryable body or a durable receipt.
    func acknowledge(responseData: Data, externalID: String) throws {
        try transaction {
            guard let record = try row(externalID) else { throw Failure.notFound }
            let prior = try record.receipt.map { try HubStorageReceipt.decode($0) }
            let receipt = try HubProducerContract.validateResponse(responseData: responseData,
                expected: record.expected(externalID), boundEventID: prior?.eventID)
            let processing: HubProcessingReceipt?
            if record.lane == "audio-original" {
                guard let processingObject = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any],
                      let processingValue = processingObject["processing_receipt"],
                      let processingData = try? JSONSerialization.data(withJSONObject: processingValue) else {
                    throw HubProducerError.invalidProcessingReceipt
                }
                processing = try HubProcessingReceipt.decode(processingData, expectedOriginalEventID: receipt.eventID)
            } else {
                processing = nil
            }
            if let prior {
                let priorProcessing = record.processingReceipt.flatMap {
                    try? HubProcessingReceipt.decode($0, expectedOriginalEventID: receipt.eventID)
                }
                let processingBindingMatches: Bool
                if let priorProcessing, let processing {
                    processingBindingMatches = priorProcessing.jobID == processing.jobID
                        && priorProcessing.originalEventID == processing.originalEventID
                        && priorProcessing.pipelineVersion == processing.pipelineVersion
                } else {
                    processingBindingMatches = priorProcessing == nil && processing == nil
                }
                guard receipt == prior, processingBindingMatches else { throw Failure.receiptMismatch }
                if let processing, let priorProcessing,
                   processing.state != priorProcessing.state {
                    try execute("UPDATE hub_outbox_v1 SET processing_receipt=? WHERE id=?",
                                [.blob(try JSONEncoder().encode(processing)), .text(externalID)])
                }
                return
            }
            let encoded = try JSONSerialization.data(withJSONObject: [
                "receipt_version": receipt.receiptVersion, "source": receipt.source,
                "external_id": receipt.externalID, "event_id": receipt.eventID,
                "sha256": receipt.sha256.map { $0 as Any } ?? NSNull(),
                "byte_length": receipt.byteLength, "ingest_sequence": receipt.ingestSequence
            ])
            let processingEncoded = try processing.map { try JSONEncoder().encode($0) }
            guard encoded.count + (processingEncoded?.count ?? 0) <= 3072 else { throw Failure.receiptMismatch }
            if let processingEncoded {
                try execute("UPDATE hub_outbox_v1 SET state=2, body=NULL, receipt=?, processing_receipt=?, lease_until=0, acked_at=? WHERE id=?",
                            [.blob(encoded), .blob(processingEncoded), .double(Date().timeIntervalSince1970), .text(externalID)])
            } else {
                try execute("UPDATE hub_outbox_v1 SET state=2, body=NULL, receipt=?, lease_until=0, acked_at=? WHERE id=?",
                            [.blob(encoded), .double(Date().timeIntervalSince1970), .text(externalID)])
            }
        }
    }

    /// Body-free usage of one lane, split the way the budget is spent: rows still owed to the
    /// Hub (body + one reserved page each), the acknowledged identity/receipt ledger (counted by
    /// real size), and bytes reserved by producers outside the table.
    struct LaneUsage: Sendable, Equatable {
        let lane: String
        let pendingCount: Int64
        let pendingBytes: Int64
        let acknowledgedCount: Int64
        let acknowledgedBytes: Int64
        let reservedBytes: Int64
        let capBytes: Int64
        /// Newest acknowledgement written by this build; nil on rows acknowledged before the
        /// column existed.
        let lastReceiptAt: Date?
        let lastRejectionReason: String?
        let lastRejectionAt: Date?
        let rejectionCount: Int64

        var usedBytes: Int64 { pendingBytes + acknowledgedBytes + reservedBytes }
        var ratio: Double { capBytes > 0 ? Double(usedBytes) / Double(capBytes) : 1 }
    }

    func usage() throws -> [LaneUsage] {
        try budgets.keys.sorted().map { lane in
            let key: [Binding] = [.text(lane)]
            let pendingCount = try scalar("SELECT COUNT(*) FROM hub_outbox_v1 WHERE lane=? AND state!=2", key)
            let pendingBytes = try scalar("SELECT COALESCE(SUM(\(Self.retainedCostSQL)),0) FROM hub_outbox_v1 WHERE lane=? AND state!=2", key)
            let ackCount = try scalar("SELECT COUNT(*) FROM hub_outbox_v1 WHERE lane=? AND state=2", key)
            let ackBytes = try scalar("SELECT COALESCE(SUM(\(Self.retainedCostSQL)),0) FROM hub_outbox_v1 WHERE lane=? AND state=2", key)
            let reserved = try scalar("SELECT COALESCE(SUM(bytes),0) FROM hub_reservations_v1 WHERE lane=?", key)
            let lastAck = try optionalDouble("SELECT MAX(acked_at) FROM hub_outbox_v1 WHERE lane=? AND state=2", key)
            let rejection = try rejectionSummary(lane: lane)
            return LaneUsage(lane: lane, pendingCount: pendingCount, pendingBytes: pendingBytes,
                             acknowledgedCount: ackCount, acknowledgedBytes: ackBytes, reservedBytes: reserved,
                             capBytes: budgets[lane]?.maxBytes ?? 0,
                             lastReceiptAt: lastAck.map { Date(timeIntervalSince1970: $0) },
                             lastRejectionReason: rejection.reason, lastRejectionAt: rejection.at,
                             rejectionCount: rejection.count)
        }
    }

    /// The most recent specific admission refusal (`admission_*`, not the generic
    /// `admission_failed`) and how many there have been.
    private func rejectionSummary(lane: String) throws -> (reason: String?, at: Date?, count: Int64) {
        let count = try scalar("SELECT COALESCE(SUM(count),0) FROM hub_gaps_v1 WHERE lane=? AND reason LIKE 'admission\\_%' ESCAPE '\\' AND reason!='admission_failed'", [.text(lane)])
        guard count > 0 else { return (nil, nil, 0) }
        let statement = try prepare("SELECT reason,last_at FROM hub_gaps_v1 WHERE lane=? AND reason LIKE 'admission\\_%' ESCAPE '\\' AND reason!='admission_failed' ORDER BY last_at DESC LIMIT 1", [.text(lane)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return (nil, nil, count) }
        return (try textColumn(statement, 0), Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)), count)
    }

    private func optionalDouble(_ sql: String, _ values: [Binding]) throws -> Double? {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 0)
    }

    func pendingBytes(lane: String) throws -> Int64 {
        try scalar("SELECT COALESCE(SUM(length(body)),0) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
    }

    /// Atomically reserve/release bytes owned by a producer outside this actor.
    /// A zero reservation removes the key. Existing outbox rows remain untouched.
    func setExternalReservation(lane: String, key: String, bytes: Int64, externalOriginalBytes: Int64 = 0) throws {
        guard let budget = budgets[lane], !key.isEmpty, key.utf8.count <= 256, bytes >= 0 else {
            throw Failure.invalidEnvelope
        }
        try transaction {
            if bytes == 0 {
                try execute("DELETE FROM hub_reservations_v1 WHERE lane=? AND reservation_key=?", [.text(lane), .text(key)])
                return
            }
            let retained = try scalar("SELECT COALESCE(SUM(\(Self.retainedCostSQL)),0) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
            let other = try scalar("SELECT COALESCE(SUM(bytes),0) FROM hub_reservations_v1 WHERE lane=? AND reservation_key<>?", [.text(lane), .text(key)])
            guard externalOriginalBytes >= 0, externalOriginalBytes <= budget.maxBytes,
                  bytes <= budget.maxBytes - externalOriginalBytes,
                  other <= budget.maxBytes - externalOriginalBytes - bytes,
                  retained <= budget.maxBytes - externalOriginalBytes - other - bytes else { throw Failure.laneFull }
            try execute("INSERT INTO hub_reservations_v1(lane,reservation_key,bytes) VALUES(?,?,?) ON CONFLICT(lane,reservation_key) DO UPDATE SET bytes=excluded.bytes", [.text(lane), .text(key), .int(bytes)])
        }
    }

    /// Process-owned capture reservations have no live writer after restart.
    /// Releasing these never removes source files, outbox bodies, or receipts.
    func recoverAudioCaptureReservations() throws {
        try transaction {
            try execute("DELETE FROM hub_reservations_v1 WHERE lane='audio-original' AND reservation_key LIKE 'audio-capture:%'")
        }
    }

    func externalReservedBytes(lane: String) throws -> Int64 {
        try scalar("SELECT COALESCE(SUM(bytes),0) FROM hub_reservations_v1 WHERE lane=?", [.text(lane)])
    }

    func retainedBytes(lane: String) throws -> Int64 {
        try scalar("SELECT COALESCE(SUM(\(Self.retainedCostSQL)),0) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
    }

    func contains(externalID: String) throws -> Bool { try row(externalID) != nil }

    func matchesOriginal(externalID: String, sha256: String?, byteLength: Int) throws -> Bool {
        guard let record = try row(externalID) else { return false }
        return record.originalHash == sha256 && record.originalBytes == byteLength
    }

    /// Bounded body-free gap aggregation uses the independent control reserve.
    /// At most 128 fixed route/reason pairs; full/corrupt/disk failures propagate.
    func recordGap(lane: String, reason: String, at: Date = Date()) throws {
        guard lane.utf8.count <= 64, reason.utf8.count <= 64 else { throw Failure.invalidEnvelope }
        try transaction {
            let present = try scalar("SELECT COUNT(*) FROM hub_gaps_v1 WHERE lane=? AND reason=?", [.text(lane), .text(reason)])
            if present == 0 {
                guard try scalar("SELECT COUNT(*) FROM hub_gaps_v1", []) < 128 else { throw Failure.receiptSlotsFull }
            }
            try execute("INSERT INTO hub_gaps_v1 VALUES(?,?,?,?,1) ON CONFLICT(lane,reason) DO UPDATE SET last_at=excluded.last_at,count=count+1",
                        [.text(lane), .text(reason), .double(at.timeIntervalSince1970), .double(at.timeIntervalSince1970)])
        }
    }

    func storedReceipt(externalID: String) throws -> HubStorageReceipt? {
        guard let record = try row(externalID), let receiptData = record.receipt else { return nil }
        if record.lane == "audio-original" {
            guard let processingData = record.processingReceipt,
                  let storage = try? HubStorageReceipt.decode(receiptData),
                  (try? HubProcessingReceipt.decode(processingData, expectedOriginalEventID: storage.eventID)) != nil else { return nil }
        }
        return try HubStorageReceipt.decode(receiptData)
    }

    private struct Record {
        let lane: String
        let body: Data?
        let bodyHash: String
        let originalHash: String?
        let originalBytes: Int
        let receipt: Data?
        let processingReceipt: Data?
        func expected(_ id: String) -> HubExpectedStorageReceipt {
            HubExpectedStorageReceipt(source: "recall", externalID: id, sha256: originalHash, byteLength: originalBytes)
        }
    }

    private func row(_ id: String) throws -> Record? {
        let statement = try prepare("SELECT lane,body,body_hash,original_hash,original_bytes,receipt,state,processing_receipt FROM hub_outbox_v1 WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return nil }
        let hash = try textColumn(statement, 3)
        let bytes = sqlite3_column_int64(statement, 4)
        guard bytes >= 0, let byteCount = Int(exactly: bytes) else { throw Failure.corruptRecord }
        let body = blobColumn(statement, 1)
        let receipt = blobColumn(statement, 5)
        let state = sqlite3_column_int(statement, 6)
        let processingReceipt = blobColumn(statement, 7)
        guard (state == 2 && body == nil && receipt != nil) ||
              ((state == 0 || state == 1) && body != nil && receipt == nil) else { throw Failure.corruptRecord }
        return Record(lane: try textColumn(statement, 0), body: body,
                      bodyHash: try textColumn(statement, 2), originalHash: hash.isEmpty ? nil : hash,
                      originalBytes: byteCount, receipt: receipt, processingReceipt: processingReceipt)
    }

    /// Additive, nullable column; existing rows keep NULL and nothing is rewritten.
    private func ensureColumn(_ name: String, type: String) throws {
        let statement = try prepare("PRAGMA table_info(hub_outbox_v1)")
        defer { sqlite3_finalize(statement) }
        var found = false
        while try step(statement) == SQLITE_ROW {
            if let column = sqlite3_column_text(statement, 1), String(cString: column) == name { found = true }
        }
        if !found { try execute("ALTER TABLE hub_outbox_v1 ADD COLUMN \(name) \(type)") }
    }

    private func migrateProcessingReceiptColumn() throws {
        let statement = try prepare("PRAGMA table_info(hub_outbox_v1)")
        defer { sqlite3_finalize(statement) }
        var found = false
        while try step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 1), String(cString: name) == "processing_receipt" { found = true }
        }
        if !found { try execute("ALTER TABLE hub_outbox_v1 ADD COLUMN processing_receipt BLOB") }
    }

    private func transaction<T>(_ operation: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private enum Binding { case text(String), blob(Data), int(Int64), double(Double) }
    private func prepare(_ sql: String, _ values: [Binding] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw Failure.storage(code) }
        do {
            for (index, value) in values.enumerated() {
                let position = Int32(index + 1)
                let code: Int32
                switch value {
                case .text(let string): code = sqlite3_bind_text(statement, position, string, -1, hubSQLiteTransient)
                case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(statement, position, $0.baseAddress, Int32(data.count), hubSQLiteTransient) }
                case .int(let number): code = sqlite3_bind_int64(statement, position, number)
                case .double(let number): code = sqlite3_bind_double(statement, position, number)
                }
                guard code == SQLITE_OK else { throw Failure.storage(code) }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }

    private func step(_ statement: OpaquePointer) throws -> Int32 {
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW || code == SQLITE_DONE else { throw Failure.storage(code) }
        return code
    }

    private func execute(_ sql: String, _ values: [Binding] = []) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        // PRAGMAs may yield a row; ordinary mutations complete with SQLITE_DONE.
        while try step(statement) == SQLITE_ROW {}
    }

    private func scalar(_ sql: String, _ values: [Binding]) throws -> Int64 {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { throw Failure.corruptRecord }
        return sqlite3_column_int64(statement, 0)
    }

    private func textColumn(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard let value = sqlite3_column_text(statement, column) else { throw Failure.corruptRecord }
        return String(cString: value)
    }

    private func blobColumn(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard let value = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: value, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private let hubSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
