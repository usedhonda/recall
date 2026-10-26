import XCTest
import CryptoKit
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

    func testGPSAlternatesFreshSourceClockAndHistoryWithoutChangingOtherLaneFIFO() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let box = try HubDurableOutbox(url: path, budgets: budgets())
        func sample(_ name: String, _ seconds: Double, route: HubRecallRoute = .gpsDelivery) throws -> HubProducerEnvelope {
            try HubProducerContract.makeEnvelope(route: route, deviceID: "fixture-device", observationID: name,
                occurredAt: Date(timeIntervalSince1970: seconds), timeBasis: "timestamp",
                sourcePayloadJSON: Data("{}".utf8), originalBytes: route == .audioOriginal ? Data("audio".utf8) : nil)
        }
        let old = try sample("old", 10), fresh = try sample("fresh", 30), middle = try sample("middle", 20)
        for item in [old, fresh, middle] { try await box.enqueue(item) }
        let now = Date(timeIntervalSince1970: 100)
        let first = try await box.leaseNext(lane: "gps-delivery", now: now, duration: 60)
        let second = try await box.leaseNext(lane: "gps-delivery", now: now, duration: 60)
        let third = try await box.leaseNext(lane: "gps-delivery", now: now, duration: 60)
        XCTAssertEqual(first?.encodedJSON, fresh.encodedJSON, "source time, not insertion order, owns live priority")
        XCTAssertEqual(second?.encodedJSON, old.encodedJSON, "history keeps draining")
        XCTAssertEqual(third?.encodedJSON, middle.encodedJSON)
        let held = try await box.leaseNext(lane: "gps-delivery", now: now, duration: 60)
        XCTAssertNil(held, "live priority cannot bypass active leases")
        let bytes = try await box.pendingBytes(lane: "gps-delivery")
        XCTAssertEqual(bytes, Int64(old.encodedJSON.count + fresh.encodedJSON.count + middle.encodedJSON.count))
        let reopened = try HubDurableOutbox(url: path, budgets: budgets())
        let retry = try await reopened.leaseNext(lane: "gps-delivery", now: now.addingTimeInterval(61), duration: 60)
        XCTAssertEqual(retry?.encodedJSON, fresh.encodedJSON)

        let audioOld = try sample("audio-old", 10, route: .audioOriginal)
        let audioFresh = try sample("audio-fresh", 30, route: .audioOriginal)
        try await box.enqueue(audioOld); try await box.enqueue(audioFresh)
        let audio = try await box.leaseNext(lane: "audio-original", now: now, duration: 60)
        XCTAssertEqual(audio?.encodedJSON, audioOld.encodedJSON, "other streams retain their FIFO")
    }

    private func response(_ event: HubProducerEnvelope, eventID: String = "00000000-0000-4000-8000-000000000001",
                          overrideLength: Int? = nil, processingState: String = "pending") throws -> Data {
        var response: [String: Any] = ["storage_receipt": [
            "receipt_version": 1, "source": "recall", "external_id": event.externalID,
            "event_id": eventID, "sha256": event.originalSHA256.map { $0 as Any } ?? NSNull(),
            "byte_length": overrideLength ?? event.originalByteLength, "ingest_sequence": 1
        ]]
        if event.route == .audioOriginal {
            response["processing_receipt"] = [
                "receipt_version": 1, "intent_committed": true,
                "job_id": "123e4567-e89b-12d3-a456-426614174001", "original_event_id": eventID,
                "pipeline_version": "local-stt-v1", "state": processingState
            ]
        }
        return try JSONSerialization.data(withJSONObject: response)
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
        var storageOnly = try XCTUnwrap(JSONSerialization.jsonObject(with: ack) as? [String: Any])
        storageOnly.removeValue(forKey: "processing_receipt")
        do {
            try await box.acknowledge(responseData: JSONSerialization.data(withJSONObject: storageOnly), externalID: original.externalID)
            XCTFail("storage alone cannot release audio")
        } catch { XCTAssertEqual(error as? HubProducerError, .invalidProcessingReceipt) }
        let noReceipt = try await box.storedReceipt(externalID: original.externalID)
        XCTAssertNil(noReceipt)
        try await box.acknowledge(responseData: ack, externalID: original.externalID)
        var changedJob = try XCTUnwrap(JSONSerialization.jsonObject(with: ack) as? [String: Any])
        var processing = try XCTUnwrap(changedJob["processing_receipt"] as? [String: Any])
        processing["job_id"] = "123e4567-e89b-12d3-a456-426614174002"
        changedJob["processing_receipt"] = processing
        do {
            try await box.acknowledge(responseData: JSONSerialization.data(withJSONObject: changedJob), externalID: original.externalID)
            XCTFail("the durable job binding must not change")
        } catch { XCTAssertEqual(error as? HubDurableOutbox.Failure, .receiptMismatch) }
        let completed = try response(original, processingState: "completed")
        try await box.acknowledge(responseData: completed, externalID: original.externalID)
        let reopened = try HubDurableOutbox(url: path, budgets: budgets())
        try await reopened.acknowledge(responseData: completed, externalID: original.externalID)
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
        let box = try HubDurableOutbox(url: path, budgets: budgets(bytes: Int64(original.encodedJSON.count) + 4096))
        try await box.enqueue(original)
        do { try await box.enqueue(event("two")); XCTFail("zero original bytes still uses encoded space") } catch {}
    }

    func testSourceFileBudgetAndReceiptReservationSurviveACK() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let original = try event("reserved", route: .audioOriginal)
        let required = Int64(original.encodedJSON.count) + 4096
        let box = try HubDurableOutbox(url: path, budgets: budgets(bytes: required + 10))
        do {
            try await box.enqueue(original, externalOriginalBytes: 11)
            XCTFail("source files share the finite original budget")
        } catch { XCTAssertEqual(error as? HubDurableOutbox.Failure, .laneFull) }
        try await box.enqueue(original, externalOriginalBytes: 10)
        let before = try await box.retainedBytes(lane: "audio-original")
        XCTAssertEqual(before, required)
        try await box.acknowledge(responseData: response(original), externalID: original.externalID)
        let after = try await box.retainedBytes(lane: "audio-original")
        // The body is gone; the ledger row is counted at its real size, never above one page.
        XCTAssertGreaterThan(after, 0)
        XCTAssertLessThanOrEqual(after, 4096)
    }

    func testAcknowledgedLedgerRowsAreCountedByRealSizeSoAFullLaneKeepsAdmitting() async throws {
        // 40 acknowledged rows used to cost 40 pages (163,840 B) and fill a 60,000 B lane
        // after 14; at their real size they take a fraction of it.
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let box = try HubDurableOutbox(url: path, budgets: budgets(bytes: 60_000, slots: 1_000))
        var first: HubProducerEnvelope?
        var previous: Int64 = 0
        for index in 0..<40 {
            let item = try event("ledger-\(index)")
            try await box.enqueue(item)
            let pendingCost = try await box.retainedBytes(lane: "gps-delivery")
            try await box.acknowledge(responseData: response(item), externalID: item.externalID)
            let acknowledgedCost = try await box.retainedBytes(lane: "gps-delivery")
            XCTAssertLessThanOrEqual(acknowledgedCost, pendingCost, "ACK must never need more room")
            XCTAssertGreaterThan(acknowledgedCost, previous)
            previous = acknowledgedCost
            if first == nil { first = item }
        }
        XCTAssertLessThan(previous, 40 * 4096)

        // Same identity and body: the existing receipt. Same identity, other body: a conflict.
        let again = try XCTUnwrap(first)
        try await box.enqueue(again)
        do { try await box.enqueue(event("ledger-0", value: 2)); XCTFail("changed body must conflict") }
        catch { XCTAssertEqual(error as? HubDurableOutbox.Failure, .immutableConflict) }

        // A pending row keeps its body and lease after the ledger grew.
        let waiting = try event("waiting")
        try await box.enqueue(waiting)
        let lease = try await box.leaseNext(lane: "gps-delivery", duration: 60)
        XCTAssertEqual(lease?.externalID, waiting.externalID)
        XCTAssertEqual(lease?.encodedJSON, waiting.encodedJSON)
    }

    func testGPSPressureReclaimsOnlyRetiredSnapshotReceiptsAndRestoresDrainCapacity() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let limits = try budgets(bytes: 60_000, slots: 1_000)
        let box = try HubDurableOutbox(url: path, budgets: limits)
        let sourceID = UUID()
        let source = try event(sourceID.uuidString)
        try await box.enqueue(source)
        try await box.acknowledge(responseData: response(source), externalID: source.externalID)
        let unknown = try event("legacy-shape")
        try await box.enqueue(unknown)
        try await box.acknowledge(responseData: response(unknown), externalID: unknown.externalID)
        let claimedID = UUID()
        let claimed = try event(claimedID.uuidString)
        try await box.enqueue(claimed)
        try await box.acknowledge(responseData: response(claimed), externalID: claimed.externalID)
        for _ in 0..<67 {
            let item = try event(UUID().uuidString)
            try await box.enqueue(item)
            try await box.acknowledge(responseData: response(item), externalID: item.externalID)
        }
        let waiting = try event(UUID().uuidString)
        let late = try event(UUID().uuidString)
        try await box.enqueue(waiting)
        try await box.enqueue(late)
        let lease = try await box.leaseNext(lane: "gps-delivery", duration: 60)
        XCTAssertEqual(lease?.externalID, waiting.externalID)
        let audio = try event("audio", route: .audioOriginal)
        try await box.enqueue(audio)
        try await box.acknowledge(responseData: response(audio), externalID: audio.externalID)

        var retained = try await box.retainedBytes(lane: "gps-delivery")
        try await box.setExternalReservation(lane: "gps-delivery", key: "source", bytes: 60_000 - retained - 128)
        do {
            try await box.setExternalReservation(lane: "gps-delivery", key: "legacy-batch", bytes: 21_650)
            XCTFail("a full lane must reproduce the blocked background drain")
        } catch { XCTAssertEqual(error as? HubDurableOutbox.Failure, .laneFull) }
        let candidates = try await box.gpsReceiptReclamationCandidates()
        XCTAssertEqual(candidates.count, 70)
        let claim = await box.claimGPSReceipt(observationID: claimedID)

        // This ACK was not in the snapshot; an older ownership snapshot must
        // never collect it, even if its source ID is not in the protected set.
        try await box.acknowledge(responseData: response(late), externalID: late.externalID)
        retained = try await box.retainedBytes(lane: "gps-delivery")
        try await box.setExternalReservation(lane: "gps-delivery", key: "source", bytes: 60_000 - retained - 128)
        let removed = try await box.reclaimGPSReceipts(candidates, protecting: [sourceID])
        XCTAssertGreaterThan(removed, 0)
        let kept = try await box.retainedBytes(lane: "gps-delivery")
        let reserved = try await box.externalReservedBytes(lane: "gps-delivery")
        let used = kept + reserved
        XCTAssertLessThanOrEqual(used, 30_000)
        let lowPressure = try await box.gpsReceiptReclamationCandidates()
        XCTAssertTrue(lowPressure.isEmpty)
        try await box.setExternalReservation(lane: "gps-delivery", key: "legacy-batch", bytes: 21_650)

        let reopened = try HubDurableOutbox(url: path, budgets: limits)
        for protected in [source, unknown, claimed, late, audio] {
            let receipt = try await reopened.storedReceipt(externalID: protected.externalID)
            XCTAssertNotNil(receipt)
        }
        let bodyBytes = try await reopened.pendingBytes(lane: "gps-delivery")
        XCTAssertEqual(bodyBytes, Int64(waiting.encodedJSON.count))
        let retry = try await reopened.leaseNext(lane: "gps-delivery", now: Date().addingTimeInterval(61), duration: 60)
        XCTAssertEqual(retry?.encodedJSON, waiting.encodedJSON)
        await box.releaseGPSReceiptClaim(claim)
        let afterRelease = try await box.gpsReceiptReclamationCandidates()
        let released = try await box.reclaimGPSReceipts(
            afterRelease.filter { $0.externalID == claimed.externalID }, protecting: [sourceID])
        XCTAssertEqual(released, 1)
        let retiredClaim = try await box.storedReceipt(externalID: claimed.externalID)
        XCTAssertNil(retiredClaim)
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

    func testCaptureReservationIncludesSourceFilesAndRestartPreservesPendingRows() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let original = try event("capture-budget", route: .audioOriginal)
        let rowBytes = Int64(original.encodedJSON.count) + 4096
        let limit = rowBytes + 1000
        let box = try HubDurableOutbox(url: path, budgets: budgets(bytes: limit))
        try await box.enqueue(original)
        try await box.setExternalReservation(lane: "audio-original", key: "other", bytes: 100)
        do {
            try await box.setExternalReservation(lane: "audio-original", key: "audio-capture:old",
                                                  bytes: 701, externalOriginalBytes: 200)
            XCTFail("source files, rows, and reservations must share the cap")
        } catch { XCTAssertEqual(error as? HubDurableOutbox.Failure, .laneFull) }
        try await box.setExternalReservation(lane: "audio-original", key: "audio-capture:old",
                                              bytes: 700, externalOriginalBytes: 200)
        let reopened = try HubDurableOutbox(url: path, budgets: budgets(bytes: limit))
        try await reopened.recoverAudioCaptureReservations()
        let remaining = try await reopened.externalReservedBytes(lane: "audio-original")
        let pending = try await reopened.pendingBytes(lane: "audio-original")
        XCTAssertEqual(remaining, 100)
        XCTAssertEqual(pending, Int64(original.encodedJSON.count))
    }

    func testExternalReservationSharesBudgetAndCanBeReleased() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let original = try event("reserved")
        let required = Int64(original.encodedJSON.count) + 4096
        let box = try HubDurableOutbox(url: path, budgets: budgets(bytes: required + 100))
        try await box.setExternalReservation(lane: "gps-delivery", key: "location", bytes: 101)
        let reserved = try await box.externalReservedBytes(lane: "gps-delivery")
        XCTAssertEqual(reserved, 101)
        do { try await box.enqueue(original); XCTFail("reservation must consume lane capacity") } catch {}
        try await box.setExternalReservation(lane: "gps-delivery", key: "location", bytes: 0)
        let released = try await box.externalReservedBytes(lane: "gps-delivery")
        XCTAssertEqual(released, 0)
        try await box.enqueue(original)
        try await box.enqueue(original)
    }

    func testUsageSplitsPendingAcknowledgedAndReservedWithoutReadingBodies() async throws {
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let box = try HubDurableOutbox(url: path, budgets: budgets(bytes: 100_000, slots: 100))
        let done = try event("done")
        try await box.enqueue(done)
        try await box.enqueue(event("waiting"))
        try await box.acknowledge(responseData: response(done), externalID: done.externalID)
        try await box.setExternalReservation(lane: "gps-delivery", key: "queue", bytes: 777)

        let usage = try await box.usage().first { $0.lane == "gps-delivery" }
        let lane = try XCTUnwrap(usage)
        XCTAssertEqual(lane.pendingCount, 1)
        XCTAssertEqual(lane.acknowledgedCount, 1)
        XCTAssertEqual(lane.reservedBytes, 777)
        XCTAssertEqual(lane.capBytes, 100_000)
        XCTAssertGreaterThan(lane.pendingBytes, 4096)
        XCTAssertLessThanOrEqual(lane.acknowledgedBytes, 4096)
        XCTAssertEqual(lane.usedBytes, lane.pendingBytes + lane.acknowledgedBytes + 777)
        XCTAssertNotNil(lane.lastReceiptAt)
    }

    @MainActor
    func testRefusalReasonsAreFixedAndUsageWarnsOnTransitionsOnly() {
        XCTAssertEqual(HubDeliveryService.admissionRefusalReason(HubDurableOutbox.Failure.laneFull), "admission_lane_full")
        XCTAssertEqual(HubDeliveryService.admissionRefusalReason(HubDurableOutbox.Failure.receiptSlotsFull), "admission_ledger_full")
        XCTAssertEqual(HubDeliveryService.admissionRefusalReason(HubDurableOutbox.Failure.immutableConflict), "admission_conflict")
        XCTAssertEqual(HubDeliveryService.admissionRefusalReason(CocoaError(.fileWriteOutOfSpace)), "admission_persistence")

        XCTAssertEqual(HubDeliveryService.usageTransition(wasHigh: false, ratio: 0.81), .becameHigh)
        XCTAssertNil(HubDeliveryService.usageTransition(wasHigh: true, ratio: 0.95), "no repeat while it stays high")
        XCTAssertNil(HubDeliveryService.usageTransition(wasHigh: true, ratio: 0.75), "hysteresis between 70% and 80%")
        XCTAssertEqual(HubDeliveryService.usageTransition(wasHigh: true, ratio: 0.69), .recovered)
        XCTAssertNil(HubDeliveryService.usageTransition(wasHigh: false, ratio: 0.5))
    }

    func testOnlyAWholeSecondSampleFromAnOldQueueFileMayLoseItsMilliseconds() throws {
        // Admitted at 12:00:00.789. A queue file that stored whole seconds hands back 12:00:00.000.
        let payload = Data("{\"value\":1}".utf8)
        let admittedAt = Date(timeIntervalSince1970: 1_790_000_000.789)
        let wholeSecond = Date(timeIntervalSince1970: 1_790_000_000)
        let stored = try HubProducerContract.makeEnvelope(
            route: .gpsDelivery, deviceID: "fixture-device", observationID: "fix",
            occurredAt: admittedAt, timeBasis: "timestamp", sourcePayloadJSON: payload)
        let storedHash = SHA256.hash(data: stored.encodedJSON).map { String(format: "%02x", $0) }.joined()

        func matches(at date: Date, allowLost: Bool, body: Data = payload, id: String = "fix") -> Bool {
            HubProducerContract.matchesStoredEnvelope(
                storedBodyHash: storedHash, route: .gpsDelivery, deviceID: "fixture-device",
                observationID: id, occurredAt: date, timeBasis: "timestamp", sourcePayloadJSON: body,
                allowLostMilliseconds: allowLost)
        }
        XCTAssertTrue(matches(at: admittedAt, allowLost: false), "the exact envelope needs no search")
        XCTAssertFalse(matches(at: wholeSecond, allowLost: false),
                       "a sample recorded with milliseconds is never searched")
        XCTAssertTrue(matches(at: wholeSecond, allowLost: true),
                      "an old whole-second queue sample may have lost them")
        XCTAssertFalse(matches(at: Date(timeIntervalSince1970: 1_790_000_000.5), allowLost: true),
                       "a time that still has milliseconds is not lost precision")
        XCTAssertFalse(matches(at: Date(timeIntervalSince1970: 1_790_000_001), allowLost: true), "another second")
        XCTAssertFalse(matches(at: wholeSecond, allowLost: true, body: Data("{\"value\":2}".utf8)), "changed content")
        XCTAssertFalse(matches(at: wholeSecond, allowLost: true, id: "other"), "another identity")
    }

    func testTheQueueFileKeepsMillisecondsAndStillReadsWholeSecondFiles() throws {
        let sample = Date(timeIntervalSince1970: 1_790_000_000.789)
        let data = try LocationQueueCoding.encoder().encode([sample])
        let back = try LocationQueueCoding.decoder().decode([Date].self, from: data)
        XCTAssertEqual(back.first?.timeIntervalSince1970 ?? 0, sample.timeIntervalSince1970, accuracy: 0.0005)

        let legacy = Data("[\"2026-10-14T04:00:00Z\"]".utf8)
        let old = try LocationQueueCoding.decoder().decode([Date].self, from: legacy)
        XCTAssertEqual(old.count, 1)
    }

    func testRoundedGPSQueueBoundaryRecoversOnlyTheExactStoredPayloadAndNewClocksStayLossless() async throws {
        struct Payload: Encodable { let timestamp: Date; let value: Int }
        let originalAt = Date(timeIntervalSince1970: 1_790_000_000.9998)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldQueue = try JSONEncoder().encode([formatter.string(from: originalAt)])
        let restored = try XCTUnwrap(LocationQueueCoding.decoder().decode([Date].self, from: oldQueue).first)
        XCTAssertEqual(restored.timeIntervalSince1970, 1_790_000_001)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(Payload(timestamp: originalAt, value: 1))
        let reloaded = try encoder.encode(Payload(timestamp: restored, value: 1))
        let event = try HubProducerContract.makeEnvelope(route: .gpsDelivery, deviceID: "fixture-device",
            observationID: "boundary", occurredAt: originalAt, timeBasis: "timestamp", sourcePayloadJSON: original)
        let path = url()
        defer { try? FileManager.default.removeItem(at: path) }
        let box = try HubDurableOutbox(url: path, budgets: budgets())
        try await box.enqueue(event)
        let unacknowledged = try await box.storedReceipt(externalID: event.externalID)
        XCTAssertNil(unacknowledged, "fingerprint equivalence is never a receipt")
        try await box.acknowledge(responseData: response(event), externalID: event.externalID)
        let receipt = try await box.storedReceipt(externalID: event.externalID)
        XCTAssertNotNil(receipt)
        let fingerprint = try await box.storedBodyHash(externalID: event.externalID)
        let storedHash = try XCTUnwrap(fingerprint)

        func matches(_ payload: Data, at date: Date = restored, id: String = "boundary", legacyMS: Bool) -> Bool {
            HubProducerContract.matchesStoredEnvelope(storedBodyHash: storedHash, route: .gpsDelivery,
                deviceID: "fixture-device", observationID: id, occurredAt: date, timeBasis: "timestamp",
                sourcePayloadJSON: payload, allowRoundedSourceTimestamp: legacyMS)
        }
        XCTAssertFalse(matches(reloaded, legacyMS: false), "the pre-fix queue representation conflicts")
        XCTAssertTrue(matches(reloaded, legacyMS: true), "only the fully matching archived candidate recovers")
        XCTAssertFalse(matches(try encoder.encode(Payload(timestamp: restored, value: 2)), legacyMS: true))
        XCTAssertFalse(matches(reloaded, id: "other", legacyMS: true))
        XCTAssertFalse(matches(reloaded, at: restored.addingTimeInterval(0.1), legacyMS: true))
        XCTAssertFalse(matches(reloaded, legacyMS: false), "new lossless-clock rows never explore old representations")

        // Converting Date's reference clock to Unix seconds loses one ULP here,
        // crossing the wire encoder's whole-second boundary even before JSON.
        let referenceEdge = Date(timeIntervalSinceReferenceDate:
            (1_800_000_000 - Date.timeIntervalBetween1970AndReferenceDate).nextDown)
        for sourceDate in [originalAt, referenceEdge] {
            let sample = LocationSample(latitude: 1, longitude: 2, accuracy: 10, altitude: nil,
                speed: nil, timestamp: sourceDate)
            let persisted = try LocationQueueCoding.encoder().encode([sample])
            let roundtrip = try XCTUnwrap(LocationQueueCoding.decoder().decode([LocationSample].self, from: persisted).first)
            XCTAssertEqual(roundtrip.measurementTimestamp, sourceDate, "the source Date must survive bit-for-bit")
            XCTAssertEqual(roundtrip.timePrecision, "reference")
            XCTAssertEqual(try encoder.encode(Payload(timestamp: roundtrip.measurementTimestamp, value: 1)),
                try encoder.encode(Payload(timestamp: sourceDate, value: 1)))
            let wire = TelemetrySample(from: roundtrip)
            XCTAssertEqual(wire.timestamp, sourceDate)
            let persistedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [[String: Any]])
            XCTAssertTrue(persistedObject[0]["timestamp"] is String, "older queue readers keep their string format")
        }
        XCTAssertTrue(matches(original, at: originalAt, legacyMS: false))
    }
}
