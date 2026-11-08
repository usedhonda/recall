import Foundation
import SmartRingKit
import XCTest
@testable import recall

final class SmartRingTests: XCTestCase {
    private let peripheral = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

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
    }
}
