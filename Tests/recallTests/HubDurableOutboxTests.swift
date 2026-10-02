import XCTest
@testable import recall

final class HubDurableOutboxTests: XCTestCase {
    private func assertThrowsAsync(_ operation: () async throws -> Void,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) async {
        do { try await operation(); XCTFail("expected error", file: file, line: line) }
        catch { }
    }
    private func makeOutbox(bytes: Int64 = 1024, items: Int64 = 4, tombstones: Int64 = 4) throws -> (HubDurableOutbox, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hub-outbox-\(UUID().uuidString).sqlite")
        let budget = try HubDurableOutbox.LaneBudget(maxBytes: bytes, maxItems: items, maxTombstones: tombstones)
        return (try HubDurableOutbox(url: url, budgets: ["audio": budget, "location": budget]), url)
    }

    private func envelope(_ id: String, lane: String = "audio", body: String = "body") throws -> HubDurableOutbox.Envelope {
        let data = Data(body.utf8)
        return try HubDurableOutbox.Envelope(id: id, lane: lane, encoded: data, identity: "identity-\(id)", sha256: "hash-\(id)", byteLength: Int64(data.count))
    }

    func testLeaseExpiryReopensWithStableBytes() async throws {
        let (outbox, url) = try makeOutbox(); defer { try? FileManager.default.removeItem(at: url) }
        try await outbox.enqueue(envelope("one"))
        let first = try await outbox.leaseNext(lane: "audio", now: Date(timeIntervalSince1970: 10), duration: 1)
        let reopened = try await outbox.leaseNext(lane: "audio", now: Date(timeIntervalSince1970: 12), duration: 1)
        XCTAssertEqual(first?.envelope, reopened?.envelope)
        XCTAssertEqual(try await outbox.pendingBytes(lane: "audio"), 4)
    }

    func testMismatchedReceiptNeverAcknowledges() async throws {
        let (outbox, url) = try makeOutbox(); defer { try? FileManager.default.removeItem(at: url) }
        try await outbox.enqueue(envelope("one"))
        let bad = HubDurableOutbox.Receipt(id: "one", lane: "audio", identity: "wrong", sha256: "hash-one", byteLength: 4, eventID: "event")
        await assertThrowsAsync { try await outbox.acknowledge(bad) }
        XCTAssertEqual(try await outbox.pendingBytes(lane: "audio"), 4)
    }

    func testLostResponseDuplicateReceiptIsIdempotentAndPersistent() async throws {
        let (outbox, url) = try makeOutbox(); defer { try? FileManager.default.removeItem(at: url) }
        try await outbox.enqueue(envelope("one"))
        let receipt = HubDurableOutbox.Receipt(id: "one", lane: "audio", identity: "identity-one", sha256: "hash-one", byteLength: 4, eventID: "event")
        try await outbox.acknowledge(receipt)
        try await outbox.acknowledge(receipt)
        let reopened = try HubDurableOutbox(url: url, budgets: ["audio": try .init(maxBytes: 1024, maxItems: 4, maxTombstones: 4), "location": try .init(maxBytes: 1024, maxItems: 4, maxTombstones: 4)])
        XCTAssertEqual(try await reopened.pendingBytes(lane: "audio"), 0)
        await assertThrowsAsync { try await reopened.acknowledge(HubDurableOutbox.Receipt(id: "one", lane: "audio", identity: "identity-one", sha256: "hash-one", byteLength: 4, eventID: "other")) }
    }

    func testBudgetsAreIndependentAndFullRejectsOnlyOwnLane() async throws {
        let (outbox, url) = try makeOutbox(bytes: 4, items: 2); defer { try? FileManager.default.removeItem(at: url) }
        try await outbox.enqueue(envelope("a", lane: "audio"))
        await assertThrowsAsync { try await outbox.enqueue(envelope("b", lane: "audio")) }
        try await outbox.enqueue(envelope("l", lane: "location"))
    }

    func testInvalidPersistencePathDoesNotReportSuccess() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("missing.sqlite")
        let budget = try HubDurableOutbox.LaneBudget(maxBytes: 10, maxItems: 1, maxTombstones: 1)
        XCTAssertThrowsError(try HubDurableOutbox(url: url, budgets: ["audio": budget]))
    }
}
