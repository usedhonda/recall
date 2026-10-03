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
            try execute("CREATE TABLE IF NOT EXISTS hub_outbox_v1 (id TEXT PRIMARY KEY, lane TEXT NOT NULL, body BLOB, body_hash TEXT NOT NULL, original_hash TEXT NOT NULL, original_bytes INTEGER NOT NULL, state INTEGER NOT NULL DEFAULT 0, lease_until REAL NOT NULL DEFAULT 0, receipt BLOB)")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    /// Same ID and bytes is a retry, including after ACK. Different immutable
    /// bytes conflict. Reserve a receipt slot now so ACK cannot exhaust it later.
    func enqueue(_ envelope: HubProducerEnvelope) throws {
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
            let used = try scalar("SELECT COALESCE(SUM(length(body)),0) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
            let pending = try scalar("SELECT COUNT(*) FROM hub_outbox_v1 WHERE lane=? AND state!=2", [.text(lane)])
            let reserved = try scalar("SELECT COUNT(*) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
            let bytes = Int64(envelope.encodedJSON.count)
            let originalBytes = Int64(envelope.originalByteLength)
            let usedOriginal = try scalar("SELECT COALESCE(SUM(CASE WHEN state!=2 THEN original_bytes ELSE 0 END),0) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
            guard bytes <= budget.maxBytes, used <= budget.maxBytes - bytes,
                  originalBytes <= budget.maxOriginalBytes,
                  usedOriginal <= budget.maxOriginalBytes - originalBytes,
                  pending < budget.maxItems else { throw Failure.laneFull }
            guard reserved < budget.maxTombstones else { throw Failure.receiptSlotsFull }
            try execute("INSERT INTO hub_outbox_v1(id,lane,body,body_hash,original_hash,original_bytes) VALUES(?,?,?,?,?,?)",
                [.text(envelope.externalID), .text(lane), .blob(envelope.encodedJSON), .text(hash),
                 .text(envelope.originalSHA256 ?? ""), .int(Int64(envelope.originalByteLength))])
        }
    }

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
            if let prior {
                guard receipt == prior else { throw Failure.receiptMismatch }
                return
            }
            let encoded = try JSONSerialization.data(withJSONObject: [
                "receipt_version": receipt.receiptVersion, "source": receipt.source,
                "external_id": receipt.externalID, "event_id": receipt.eventID,
                "sha256": receipt.sha256.map { $0 as Any } ?? NSNull(),
                "byte_length": receipt.byteLength, "ingest_sequence": receipt.ingestSequence
            ])
            try execute("UPDATE hub_outbox_v1 SET state=2, body=NULL, receipt=?, lease_until=0 WHERE id=?",
                        [.blob(encoded), .text(externalID)])
        }
    }

    func pendingBytes(lane: String) throws -> Int64 {
        try scalar("SELECT COALESCE(SUM(length(body)),0) FROM hub_outbox_v1 WHERE lane=?", [.text(lane)])
    }

    func storedReceipt(externalID: String) throws -> HubStorageReceipt? {
        try row(externalID)?.receipt.map { try HubStorageReceipt.decode($0) }
    }

    private struct Record {
        let lane: String
        let body: Data?
        let bodyHash: String
        let originalHash: String?
        let originalBytes: Int
        let receipt: Data?
        func expected(_ id: String) -> HubExpectedStorageReceipt {
            HubExpectedStorageReceipt(source: "recall", externalID: id, sha256: originalHash, byteLength: originalBytes)
        }
    }

    private func row(_ id: String) throws -> Record? {
        let statement = try prepare("SELECT lane,body,body_hash,original_hash,original_bytes,receipt,state FROM hub_outbox_v1 WHERE id=?", [.text(id)])
        defer { sqlite3_finalize(statement) }
        guard try step(statement) == SQLITE_ROW else { return nil }
        let hash = try textColumn(statement, 3)
        let bytes = sqlite3_column_int64(statement, 4)
        guard bytes >= 0, let byteCount = Int(exactly: bytes) else { throw Failure.corruptRecord }
        let body = blobColumn(statement, 1)
        let receipt = blobColumn(statement, 5)
        let state = sqlite3_column_int(statement, 6)
        guard (state == 2 && body == nil && receipt != nil) ||
              ((state == 0 || state == 1) && body != nil && receipt == nil) else { throw Failure.corruptRecord }
        return Record(lane: try textColumn(statement, 0), body: body,
                      bodyHash: try textColumn(statement, 2), originalHash: hash.isEmpty ? nil : hash,
                      originalBytes: byteCount, receipt: receipt)
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
