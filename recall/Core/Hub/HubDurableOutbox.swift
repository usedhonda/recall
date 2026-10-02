import Foundation
import SQLite3

/// Durable, lane-isolated storage for Hub envelopes. This is deliberately a
/// storage primitive: admission to physical/staging files is a separate layer.
public actor HubDurableOutbox {
    public struct LaneBudget: Sendable, Equatable {
        public let maxBytes: Int64
        public let maxItems: Int64
        public let maxTombstones: Int64

        public init(maxBytes: Int64, maxItems: Int64, maxTombstones: Int64) throws {
            guard maxBytes > 0, maxItems > 0, maxTombstones > 0 else {
                throw Error.invalidBudget
            }
            self.maxBytes = maxBytes
            self.maxItems = maxItems
            self.maxTombstones = maxTombstones
        }
    }

    public struct Envelope: Sendable, Equatable {
        public let id: String
        public let lane: String
        public let encoded: Data
        public let identity: String
        public let sha256: String
        public let byteLength: Int64

        public init(id: String, lane: String, encoded: Data, identity: String,
                    sha256: String, byteLength: Int64) throws {
            guard !id.isEmpty, !lane.isEmpty, !identity.isEmpty,
                  !sha256.isEmpty, byteLength >= 0,
                  Int64(encoded.count) == byteLength else { throw Error.invalidEnvelope }
            self.id = id; self.lane = lane; self.encoded = encoded
            self.identity = identity; self.sha256 = sha256.lowercased()
            self.byteLength = byteLength
        }
    }

    public struct LeasedEnvelope: Sendable, Equatable {
        public let envelope: Envelope
        public let leaseUntil: Date
    }

    public struct Receipt: Sendable, Equatable {
        public let id: String
        public let lane: String
        public let identity: String
        public let sha256: String
        public let byteLength: Int64
        public let eventID: String

        public init(id: String, lane: String, identity: String, sha256: String,
                    byteLength: Int64, eventID: String) {
            self.id = id; self.lane = lane; self.identity = identity
            self.sha256 = sha256.lowercased(); self.byteLength = byteLength
            self.eventID = eventID
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidBudget, invalidEnvelope, invalidLease
        case laneBudgetExceeded, tombstoneBudgetExceeded
        case immutableConflict, notFound, receiptMismatch
        case sqlite(String)
    }

    private let db: OpaquePointer

    public init(url: URL, budgets: [String: LaneBudget]) throws {
        guard !budgets.isEmpty, budgets.keys.allSatisfy({ !$0.isEmpty }) else { throw Error.invalidBudget }
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let handle else { throw Error.sqlite("open:\(rc)") }
        db = handle
        do {
            try exec("PRAGMA synchronous=FULL")
            try exec("PRAGMA foreign_keys=ON")
            try exec("CREATE TABLE IF NOT EXISTS outbox (id TEXT PRIMARY KEY, lane TEXT NOT NULL, envelope BLOB NOT NULL, identity TEXT NOT NULL, sha256 TEXT NOT NULL, byte_length INTEGER NOT NULL, state INTEGER NOT NULL, lease_until REAL, created_at REAL NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS tombstones (id TEXT PRIMARY KEY, lane TEXT NOT NULL, identity TEXT NOT NULL, sha256 TEXT NOT NULL, byte_length INTEGER NOT NULL, event_id TEXT NOT NULL, bound_at REAL NOT NULL)")
            try exec("CREATE TABLE IF NOT EXISTS lane_budgets (lane TEXT PRIMARY KEY, max_bytes INTEGER NOT NULL, max_items INTEGER NOT NULL, max_tombstones INTEGER NOT NULL)")
            for (lane, budget) in budgets {
                try upsertBudget(lane: lane, budget: budget)
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(db) }

    public func enqueue(_ envelope: Envelope) throws {
        guard let budget = try budget(for: envelope.lane) else { throw Error.invalidBudget }
        let existing = try queryOne("SELECT lane, identity, sha256, byte_length FROM outbox WHERE id=? OR id IN (SELECT id FROM tombstones WHERE id=?)", binds: [.text(envelope.id), .text(envelope.id)])
        if let existing {
            if existing[0] != envelope.lane || existing[1] != envelope.identity || existing[2] != envelope.sha256 || existing[3] != String(envelope.byteLength) { throw Error.immutableConflict }
            throw Error.immutableConflict
        }
        let used = try scalarInt64("SELECT COALESCE(SUM(byte_length),0) FROM outbox WHERE lane=?", binds: [.text(envelope.lane)])
        let count = try scalarInt64("SELECT COUNT(*) FROM outbox WHERE lane=?", binds: [.text(envelope.lane)])
        let tombstones = try scalarInt64("SELECT COUNT(*) FROM tombstones WHERE lane=?", binds: [.text(envelope.lane)])
        guard used <= budget.maxBytes - envelope.byteLength, count < budget.maxItems else { throw Error.laneBudgetExceeded }
        guard tombstones <= budget.maxTombstones else { throw Error.tombstoneBudgetExceeded }
        try exec("BEGIN IMMEDIATE")
        do {
            try insert(envelope)
            try exec("COMMIT")
        } catch { _ = try? exec("ROLLBACK"); throw error }
    }

    public func leaseNext(lane: String, now: Date = Date(), duration: TimeInterval) throws -> LeasedEnvelope? {
        guard duration > 0 else { throw Error.invalidLease }
        let nowValue = now.timeIntervalSince1970
        let row = try queryEnvelope("SELECT id,lane,envelope,identity,sha256,byte_length FROM outbox WHERE lane=? AND (state=0 OR (state=1 AND lease_until<=?)) ORDER BY created_at,id LIMIT 1", binds: [.text(lane), .double(nowValue)])
        guard let envelope = row else { return nil }
        let until = nowValue + duration
        try exec("UPDATE outbox SET state=1, lease_until=? WHERE id=?", binds: [.double(until), .text(envelope.id)])
        return LeasedEnvelope(envelope: envelope, leaseUntil: Date(timeIntervalSince1970: until))
    }

    /// Verifies the complete receipt and atomically binds eventID while moving
    /// the payload to its metadata-only tombstone. A duplicate receipt for the
    /// same immutable ID/event is idempotent; a different receipt is rejected.
    public func acknowledge(_ receipt: Receipt, receivedAt: Date = Date()) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            if let row = try queryOne("SELECT lane,identity,sha256,byte_length FROM outbox WHERE id=?", binds: [.text(receipt.id)]) {
                guard row[0] == receipt.lane, row[1] == receipt.identity,
                      row[2] == receipt.sha256, row[3] == String(receipt.byteLength) else { throw Error.receiptMismatch }
                try exec("INSERT INTO tombstones(id,lane,identity,sha256,byte_length,event_id,bound_at) VALUES(?,?,?,?,?,?,?)", binds: [.text(receipt.id), .text(receipt.lane), .text(receipt.identity), .text(receipt.sha256), .int(receipt.byteLength), .text(receipt.eventID), .double(receivedAt.timeIntervalSince1970)])
                try exec("DELETE FROM outbox WHERE id=?", binds: [.text(receipt.id)])
            } else if let row = try queryOne("SELECT lane,identity,sha256,byte_length,event_id FROM tombstones WHERE id=?", binds: [.text(receipt.id)]) {
                guard row[0] == receipt.lane, row[1] == receipt.identity, row[2] == receipt.sha256,
                      row[3] == String(receipt.byteLength), row[4] == receipt.eventID else { throw Error.receiptMismatch }
            } else { throw Error.notFound }
            try exec("COMMIT")
        } catch { _ = try? exec("ROLLBACK"); throw error }
    }

    /// Validates a Hub response through the shared wire contract before the
    /// durable ACK transaction. Callers pass the immutable ID/lane recorded at
    /// enqueue time; no response bytes are logged or retained.
    public func acknowledge(responseData: Data, id: String, lane: String,
                            identity: String, expected: HubExpectedStorageReceipt,
                            boundEventID: String? = nil, receivedAt: Date = Date()) throws {
        let receipt = try HubProducerContract.validateResponse(responseData: responseData,
                                                               expected: expected,
                                                               boundEventID: boundEventID)
        try acknowledge(Receipt(id: id, lane: lane, identity: identity,
                                sha256: receipt.sha256 ?? "", byteLength: receipt.byteLength,
                                eventID: receipt.eventID), receivedAt: receivedAt)
    }

    public func pendingBytes(lane: String) throws -> Int64 { try scalarInt64("SELECT COALESCE(SUM(byte_length),0) FROM outbox WHERE lane=?", binds: [.text(lane)]) }

    private enum Bind { case text(String), int(Int64), double(Double), blob(Data) }
    private func upsertBudget(lane: String, budget: LaneBudget) throws { try exec("INSERT INTO lane_budgets VALUES(?,?,?,?) ON CONFLICT(lane) DO UPDATE SET max_bytes=excluded.max_bytes,max_items=excluded.max_items,max_tombstones=excluded.max_tombstones", binds: [.text(lane), .int(budget.maxBytes), .int(budget.maxItems), .int(budget.maxTombstones)]) }
    private func budget(for lane: String) throws -> LaneBudget? {
        guard let r = try queryOne("SELECT max_bytes,max_items,max_tombstones FROM lane_budgets WHERE lane=?", binds: [.text(lane)]) else { return nil }
        return try LaneBudget(maxBytes: Int64(r[0])!, maxItems: Int64(r[1])!, maxTombstones: Int64(r[2])!)
    }
    private func insert(_ e: Envelope) throws { try exec("INSERT INTO outbox VALUES(?,?,?,?,?,?,?,?,?)", binds: [.text(e.id), .text(e.lane), .blob(e.encoded), .text(e.identity), .text(e.sha256), .int(e.byteLength), .int(0), .double(0), .double(Date().timeIntervalSince1970)]) }
    private func queryEnvelope(_ sql: String, binds: [Bind]) throws -> Envelope? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqliteError() }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt, binds)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw sqliteError() }
        guard rc == SQLITE_ROW else { return nil }
        guard let bytes = sqlite3_column_blob(stmt, 2) else { throw Error.sqlite("invalid blob") }
        let length = Int(sqlite3_column_bytes(stmt, 2))
        let data = Data(bytes: bytes, count: length)
        guard let idPtr = sqlite3_column_text(stmt, 0), let lanePtr = sqlite3_column_text(stmt, 1),
              let identityPtr = sqlite3_column_text(stmt, 3), let hashPtr = sqlite3_column_text(stmt, 4) else { throw Error.sqlite("invalid row") }
        return try Envelope(id: String(cString: idPtr), lane: String(cString: lanePtr), encoded: data,
                            identity: String(cString: identityPtr), sha256: String(cString: hashPtr),
                            byteLength: sqlite3_column_int64(stmt, 5))
    }
    private func scalarInt64(_ sql: String, binds: [Bind]) throws -> Int64 { Int64((try queryOne(sql, binds: binds))?.first ?? "0") ?? 0 }
    private func queryOne(_ sql: String, binds: [Bind]) throws -> [String]? { try queryRow(sql, binds: binds) }
    private func queryRow(_ sql: String, binds: [Bind]) throws -> [String]? {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqliteError() }; defer { sqlite3_finalize(stmt) }
        try bind(stmt, binds); let rc = sqlite3_step(stmt); guard rc == SQLITE_ROW || rc == SQLITE_DONE else { throw sqliteError() }; guard rc == SQLITE_ROW else { return nil }
        return (0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_text(stmt, $0)) }
    }
    private func exec(_ sql: String, binds: [Bind] = []) throws { var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw sqliteError() }; defer { sqlite3_finalize(stmt) }; try bind(stmt, binds); guard sqlite3_step(stmt) == SQLITE_DONE else { throw sqliteError() } }
    private func bind(_ stmt: OpaquePointer?, _ binds: [Bind]) throws { for (i, b) in binds.enumerated() { let idx = Int32(i + 1); let rc: Int32; switch b { case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT); case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v); case .double(let v): rc = sqlite3_bind_double(stmt, idx, v); case .blob(let d): rc = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) } }; guard rc == SQLITE_OK else { throw sqliteError() } } }
    private func sqliteError() -> Error { Error.sqlite(String(cString: sqlite3_errmsg(db))) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
