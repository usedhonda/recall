import XCTest
@testable import recall

final class HubDurableOutboxTests: XCTestCase {
    private func event(_ id: String, route: HubRecallRoute = .gpsDelivery,
                       value: Int = 1) throws -> HubProducerEnvelope {
        try HubProducerContract.makeEnvelope(route: route, deviceID: "fixture-device", observationID: id,
            occurredAt: Date(timeIntervalSince1970: 1), timeBasis: "timestamp",
            sourcePayloadJSON: Data("{\"value\":\(value)}".utf8),
            originalBytes: route == .audioOriginal ? Data("audio-fixture".utf8) : nil)
    }

    private func budgets(bytes: Int64 = 100_000, slots: Int64 = 8) throws -> [String: HubDurableOutbox.LaneBudget] {
        let budget = try HubDurableOutbox.LaneBudget(maxBytes: bytes, maxItems: 8, maxTombstones: slots)
        return ["audio-original": budget, "gps-delivery": budget]
    }

    private func url() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hub-\(UUID().uuidString).sqlite")
    }

    private func response(_ event: HubProducerEnvelope, eventID: String = "00000000-0000-4000-8000-000000000001",
                          overrideLength: Int? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["storage_receipt": [
            "receipt_version": 1, "source": "recall", "external_id": event.externalID,
            "event_id": eventID, "sha256": event.originalSHA256.map { $0 as Any } ?? NSNull(),
            "byte_length": overrideLength ?? event.originalByteLength, "ingest_sequence": 1
        ]])
    }

    func testReopenedLeasePreservesBytesAndNeverDrainsBeforeACK() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let original = try event("one")
        let first = try HubDurableOutbox(url: path, budgets: budgets())
        try await first.enqueue(original)
        let lease = try await first.leaseNext(lane: "gps-delivery", now: Date(timeIntervalSince1970: 10), duration: 2)
        let reopened = try HubDurableOutbox(url: path, budgets: budgets())
        let locked = try await reopened.leaseNext(lane: "gps-delivery", now: Date(timeIntervalSince1970: 11), duration: 2)
        XCTAssertNil(locked)
        let retried = try await reopened.leaseNext(lane: "gps-delivery", now: Date(timeIntervalSince1970: 13), duration: 2)
        XCTAssertEqual(lease?.encodedJSON, retried?.encodedJSON)
        XCTAssertEqual(retried?.encodedJSON, original.encodedJSON)
        let bytes = try await reopened.pendingBytes(lane: "gps-delivery")
        XCTAssertEqual(bytes, Int64(original.encodedJSON.count))
    }

    func testOriginalReceiptMismatchRetainsAndValidACKPersistsBinding() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let original = try event("one", route: .audioOriginal)
        let box = try HubDurableOutbox(url: path, budgets: budgets())
        try await box.enqueue(original)
        do {
            try await box.acknowledge(responseData: response(original, overrideLength: 0), externalID: original.externalID)
            XCTFail("wrong original length must not ACK")
        } catch {}
        let remaining = try await box.pendingBytes(lane: "audio-original")
        XCTAssertEqual(remaining, Int64(original.encodedJSON.count))
        let ack = try response(original)
        try await box.acknowledge(responseData: ack, externalID: original.externalID)
        let reopened = try HubDurableOutbox(url: path, budgets: budgets())
        try await reopened.acknowledge(responseData: ack, externalID: original.externalID)
        let receipt = try await reopened.storedReceipt(externalID: original.externalID)
        XCTAssertEqual(receipt?.sha256, original.originalSHA256)
        let pending = try await reopened.pendingBytes(lane: "audio-original")
        XCTAssertEqual(pending, 0)
        do {
            try await reopened.acknowledge(responseData: response(original,
                eventID: "00000000-0000-4000-8000-000000000002"), externalID: original.externalID)
            XCTFail("stored event ID cannot change")
        } catch {}
    }

    func testDuplicateSameBodyIsIdempotentBeforeAndAfterACKButChangedBodyConflicts() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let box = try HubDurableOutbox(url: path, budgets: budgets())
        let original = try event("one")
        try await box.enqueue(original)
        try await box.enqueue(original)
        do { try await box.enqueue(event("one", value: 2)); XCTFail("immutable conflict") } catch {}
        try await box.acknowledge(responseData: response(original), externalID: original.externalID)
        try await box.enqueue(original)
        do { try await box.enqueue(event("one", value: 2)); XCTFail("tombstone conflict") } catch {}
        let lease = try await box.leaseNext(lane: "gps-delivery", duration: 1)
        XCTAssertNil(lease)
    }

    func testFullLaneDoesNotConsumeOtherLaneAndReservesReceiptSlots() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let box = try HubDurableOutbox(url: path, budgets: budgets(slots: 1))
        let audio = try event("audio", route: .audioOriginal)
        try await box.enqueue(audio)
        do { try await box.enqueue(event("next", route: .audioOriginal)); XCTFail("receipt slot reserved") } catch {}
        try await box.enqueue(event("gps"))
        try await box.acknowledge(responseData: response(audio), externalID: audio.externalID)
        do { try await box.enqueue(event("next", route: .audioOriginal)); XCTFail("tombstone retained") } catch {}
    }

    func testEncodedByteBudgetNotOriginalByteCount() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let original = try event("one")
        let box = try HubDurableOutbox(url: path, budgets: budgets(bytes: Int64(original.encodedJSON.count)))
        try await box.enqueue(original)
        do { try await box.enqueue(event("two")); XCTFail("zero original bytes still uses encoded space") } catch {}
    }

    func testOriginalReservationIsIndependentLaneBudget() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let policy = ["audio-original": try HubDurableOutbox.LaneBudget(
            maxBytes: 100_000, maxItems: 8, maxTombstones: 8, maxOriginalBytes: 3)]
        let box = try HubDurableOutbox(url: path, budgets: policy)
        let first = try event("one", route: .audioOriginal)
        do { try await box.enqueue(first); XCTFail("fixture is larger than reservation") } catch {
            XCTAssertEqual(error as? HubDurableOutbox.Failure, .laneFull)
        }
    }

    func testConcurrentInstancesCannotOveradmitOrDoubleLease() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let policy = try budgets(slots: 1)
        let a = try HubDurableOutbox(url: path, budgets: policy)
        let b = try HubDurableOutbox(url: path, budgets: policy)
        let e1 = try event("one"), e2 = try event("two")
        let successes = await withTaskGroup(of: Bool.self) { group in
            group.addTask { do { try await a.enqueue(e1); return true } catch { return false } }
            group.addTask { do { try await b.enqueue(e2); return true } catch { return false } }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        async let first = a.leaseNext(lane: "gps-delivery", duration: 30)
        async let second = b.leaseNext(lane: "gps-delivery", duration: 30)
        let leases = try await [first, second]
        XCTAssertEqual(leases.compactMap { $0 }.count, 1)
    }

    func testPersistenceFailureDoesNotCreateEmptySuccessQueue() throws {
        let path = url().appendingPathComponent("missing.sqlite")
        XCTAssertThrowsError(try HubDurableOutbox(url: path, budgets: budgets()))
        let corrupt = url()
        defer { try? FileManager.default.removeItem(at: corrupt) }
        try Data("not sqlite".utf8).write(to: corrupt)
        XCTAssertThrowsError(try HubDurableOutbox(url: corrupt, budgets: budgets()))
    }
}
