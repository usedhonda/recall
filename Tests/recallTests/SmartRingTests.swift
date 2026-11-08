import Foundation
import SmartRingKit
import XCTest
@testable import recall

final class SmartRingTests: XCTestCase {
    private let peripheral = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @MainActor
    func testInterruptedPassNeverRequestsNextCategory() async throws {
        var attempted: [RingReadCommand] = []
        do {
            try await SmartRingManager.readCategories([.hrvHistory, .sleepHistory, .temperatureHistory]) { command in
                attempted.append(command)
                if command == .sleepHistory { throw RingError.disconnected }
            }
            XCTFail("Expected the interrupted transfer to end this pass")
        } catch RingError.disconnected {}
        XCTAssertEqual(attempted, [.hrvHistory, .sleepHistory])
    }

    func testResumeUsesPersistedOverlapAndAvailabilityDoesNotRewriteFrozenBodies() async throws {
        enum Refused: Error { case full }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func item(_ minute: UInt8) throws -> SmartRingSample {
            let record = try RingPacketDecoder.hrvRecord(Data([
                0x56, 0, 0, 0x24, 0x02, 0x29, 0x12, minute, 0, 42, 0, 65, 30, 0, 0
            ]))
            return try SmartRingSample(record: record, peripheralID: peripheral, firmware: "0.7.5.0", timeZone: TimeZone(secondsFromGMT: 0)!)
        }
        let records = try [item(0x10), item(0x20), item(0x30)]
        let store = try SmartRingStore(url: folder.appendingPathComponent("ring.json"), uploadFloor: .distantPast)
        try await store.merge(Array(records.prefix(2)), capturedAt: Date(timeIntervalSince1970: 1))
        var firstBody: Data?
        do {
            try await store.drain { body, _, _ in firstBody = body; throw Refused.full }
        } catch Refused.full {}
        let received = Date(timeIntervalSince1970: 2)
        try await store.merge(records, capturedAt: received, availableAt: received)
        let hint = await store.resumeHint(command: 0x56, deviceID: records[0].ring.deviceID,
            firmware: "0.7.5.0", timeZone: "GMT")
        XCTAssertEqual(hint?.minute, 20)
        let wrongProfile = await store.resumeHint(command: 0x56, deviceID: records[0].ring.deviceID,
            firmware: "unknown", timeZone: "GMT")
        XCTAssertNil(wrongProfile)
        let projected = await store.samplesForHealthSnapshot()
        XCTAssertTrue(projected.allSatisfy { $0.availableAt == received })
        var retries: [Data] = []
        try await store.drain { body, _, _ in retries.append(body) }
        XCTAssertEqual(retries.first, firstBody)
    }

    func testFatigueResearchKeepsAvailabilityAndEstimateDistinctFromNativeStress() throws {
        var native = try sample()
        native.availableAt = native.start.addingTimeInterval(1)
        let now = native.start.addingTimeInterval(600)
        let zone = TimeZone(identifier: "UTC")!
        let hold = try SmartRingResearch.evaluate([native], deviceID: native.ring.deviceID,
            firmware: "0.7.5.0", timeZone: zone, method: .carryForward, at: now)
        XCTAssertEqual(hold.estimate?.status, "estimated")
        XCTAssertEqual(hold.estimate?.validationStatus, "experimental_unvalidated")
        XCTAssertEqual(hold.estimate?.trainingSamples, 0)
        let model = try SmartRingResearch.evaluate([native], deviceID: native.ring.deviceID,
            firmware: "0.7.5.0", timeZone: zone, method: .learnedDecay, at: now)
        XCTAssertEqual(model.estimate?.status, "unavailable")
        XCTAssertNil(model.estimate?.value)
        native.availableAt = nil
        let legacy = try SmartRingResearch.evaluate([native], deviceID: native.ring.deviceID,
            firmware: "0.7.5.0", timeZone: zone, method: .carryForward, at: now)
        XCTAssertEqual(legacy.estimate?.reason, "no_available_anchor")
    }

    private func sample(sequence: UInt8 = 0, stress: UInt8 = 30, zone: String = "UTC") throws -> SmartRingSample {
        let record = try RingPacketDecoder.hrvRecord(Data([
            0x56, sequence, 0, 0x24, 0x02, 0x29, 0x12, 0x34, 0x56, 42, 0, 65, stress, 0, 0
        ]))
        return try SmartRingSample(record: record, peripheralID: peripheral, firmware: "0.7.5.0",
                                   timeZone: TimeZone(identifier: zone)!)
    }

    func testRingNamespacePreservesRawValuesWithoutClaimingSDNN() throws {
        let value = try sample()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: HubRawEvent.encoder.encode(value)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "smart_ring.hrv_history")
        XCTAssertEqual(object["source"] as? String, "SmartRingKit")
        XCTAssertNil(object["value"])
        XCTAssertNil(object["unit"])
        let ring = try XCTUnwrap(object["ring"] as? [String: Any])
        XCTAssertEqual(ring["hrvRaw"] as? Int, 42)
        XCTAssertEqual(ring["stressRaw"] as? Int, 30)
        XCTAssertEqual(ring["heartRateBPM"] as? Int, 65)
        XCTAssertEqual((ring["rawBytes"] as? [Int])?.count, 15)
        XCTAssertNotEqual(value.ring.deviceID, peripheral.uuidString)
        let payload = HubRawEvent.sourcePayload(items: [try HubRawEvent.encoder.encode(value)], deleted: [])
        let envelope = try HubProducerContract.makeEnvelope(route: .healthSamples, deviceID: "fixture",
            observationID: value.uuid, occurredAt: Date(timeIntervalSince1970: 0),
            timeBasis: "ring_captured_at", sourcePayloadJSON: payload)
        XCTAssertEqual(envelope.route.kind, "recall.health-samples.v1")
    }

    func testIdentityIgnoresTransferOrderButSeparatesChangedDataAndClockInterpretation() throws {
        XCTAssertEqual(try sample(sequence: 0).uuid, try sample(sequence: 5).uuid)
        XCTAssertNotEqual(try sample().uuid, try sample(stress: 31).uuid)
        XCTAssertNotEqual(try sample().uuid, try sample(zone: "Asia/Tokyo").uuid)
    }

    func testArchiveDeduplicatesAcrossRestartsAndNeverEvictsForCapacity() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ring.json")
        let store = try SmartRingStore(url: file, capacity: 1, uploadFloor: .distantPast)
        let added = try await store.merge([sample(), sample(sequence: 1)], capturedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(added, 1)
        let reopened = try SmartRingStore(url: file, capacity: 1)
        let repeated = try await reopened.merge([sample(sequence: 2)], capturedAt: Date())
        XCTAssertEqual(repeated, 0)
        do {
            try await reopened.merge([sample(stress: 31)], capturedAt: Date())
            XCTFail("expected full archive")
        } catch { XCTAssertTrue(error is SmartRingStore.Failure) }
        let counts = await reopened.counts()
        XCTAssertEqual(counts.stored, 1)
        XCTAssertEqual(counts.pending, 1)
    }

    func testFailedAdmissionFreezesExactRetryDespiteNewCaptureAndRestart() async throws {
        enum Refused: Error { case full }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("ring.json")
        let store = try SmartRingStore(url: file, uploadFloor: .distantPast)
        try await store.merge([sample()], capturedAt: Date(timeIntervalSince1970: 1.125))
        var original: (Data, String, Date)?
        do {
            try await store.drain { payload, id, date in
                original = (payload, id, date)
                throw Refused.full
            }
            XCTFail("expected refusal")
        } catch { XCTAssertTrue(error is Refused) }
        try await store.merge([sample(stress: 31)], capturedAt: Date(timeIntervalSince1970: 2))
        let reopened = try SmartRingStore(url: file)
        var admitted: [(Data, String, Date)] = []
        try await reopened.drain { admitted.append(($0, $1, $2)) }
        XCTAssertEqual(admitted.count, 2)
        XCTAssertEqual(admitted[0].0, original?.0)
        XCTAssertEqual(admitted[0].1, original?.1)
        XCTAssertEqual(admitted[0].2, original?.2)
        let counts = await reopened.counts()
        XCTAssertEqual(counts.pending, 0)
        let repeated = try await reopened.merge([sample(sequence: 6)], capturedAt: Date())
        XCTAssertEqual(repeated, 0)
    }

    func testOldHistoryIsRetainedLocallyWithoutPassingTheRetentionFloor() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SmartRingStore(url: folder.appendingPathComponent("ring.json"), uploadFloor: .distantFuture)
        try await store.merge([sample()], capturedAt: Date())
        try await store.drain { _, _, _ in XCTFail("old history must be held") }
        let counts = await store.counts()
        XCTAssertEqual(counts.stored, 1)
        XCTAssertEqual(counts.pending, 1)
        XCTAssertEqual(counts.held, 1)
        let projected = await store.samplesForHealthSnapshot()
        XCTAssertTrue(projected.isEmpty)
    }

    func testUnifiedHealthPrefersRingPulseWithoutLosingHealthKitOrConvertingRawHRV() throws {
        let ring = try sample()
        let now = ring.end.addingTimeInterval(60)
        let heart = HealthRecord(metricId: HealthDataIntegrator.heartRate, value: 80,
            valueText: nil, valueMin: 60, valueMax: 100, unit: "count/min", aggregation: "discreteStats",
            measuredAt: now, intervalStart: ring.start.addingTimeInterval(-60), intervalEnd: now,
            sampleCount: 10, source: "HealthKit fixture", sourceBundleId: "fixture.health", deviceModel: nil)
        let sleep = SleepSummary(total: 400)
        let health = HealthPayload(collectedAt: now, records: [heart], sleep: sleep, workouts: nil)
        let combined = HealthDataIntegrator.combine(healthKit: health, ring: [ring], collectedAt: now)
        let selected = try XCTUnwrap(combined.records.first { $0.metricId == HealthDataIntegrator.heartRate })
        XCTAssertEqual(selected.value, 65)
        XCTAssertEqual(selected.aggregation, "latest")
        XCTAssertEqual(selected.measuredAt, ring.end)
        XCTAssertEqual(selected.sourceObservationID, ring.uuid)
        XCTAssertEqual(combined.sourceRecords?.first?.value, 80)
        XCTAssertEqual(combined.sleep?.total, 400)
        XCTAssertEqual(combined.records.first { $0.metricId == "smart_ring.hrv_raw" }?.unit, "raw")
        XCTAssertFalse(combined.records.contains { $0.metricId.contains("SDNN") })
        let ringOnly = HealthDataIntegrator.combine(healthKit: nil, ring: [ring], collectedAt: now)
        XCTAssertNil(ringOnly.sleep)
        XCTAssertEqual(ringOnly.records.count, 3)
        let outsideInterval = HealthDataIntegrator.combine(healthKit: health,
            ring: [ring], collectedAt: ring.end.addingTimeInterval(-1))
        XCTAssertEqual(outsideInterval.records.first?.value, 80)
        XCTAssertNil(outsideInterval.sourceRecords)
        var newerHealth = health
        newerHealth.records = [HealthRecord(metricId: HealthDataIntegrator.heartRate, value: 90,
            valueText: nil, valueMin: nil, valueMax: nil, unit: "count/min", aggregation: "latest",
            measuredAt: now, intervalStart: nil, intervalEnd: nil, sampleCount: 1,
            source: "HealthKit fixture", sourceBundleId: "fixture.health", deviceModel: nil)]
        XCTAssertEqual(HealthDataIntegrator.combine(healthKit: newerHealth, ring: [ring],
            collectedAt: now).records.first?.value, 90)

        let rawPayload = HubRawEvent.sourcePayload(items: [try HubRawEvent.encoder.encode(ring)], deleted: [])
        let rawObject = try JSONSerialization.jsonObject(with: rawPayload)
        let snapshotObject = try JSONSerialization.jsonObject(with: HubRawEvent.encoder.encode(combined))
        let object = try XCTUnwrap(snapshotObject as? [String: Any])
        let wireRecords = try XCTUnwrap(object["records"] as? [[String: Any]])
        let stress = try XCTUnwrap(wireRecords.first { $0["metricId"] as? String == "smart_ring.native_fatigue_raw" })
        XCTAssertEqual(stress["unit"] as? String, "raw")
        XCTAssertEqual(stress["value"] as? Int, 30)
        XCTAssertEqual(stress["sourceObservationID"] as? String, ring.uuid)
        XCTAssertEqual((object["sourceRecords"] as? [[String: Any]])?.count, 4)
        let wireExample = try JSONSerialization.data(withJSONObject: [
            "synthetic": true,
            "raw": ["kind": "recall.health-samples.v1", "time_basis": "ring_captured_at", "source_payload": rawObject],
            "snapshot": ["kind": "recall.health-snapshot.v1", "source_payload": snapshotObject]
        ], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: wireExample, uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-ring-health-wire-contract"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
