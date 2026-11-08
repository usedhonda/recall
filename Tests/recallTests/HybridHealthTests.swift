import Foundation
import SmartRingKit
import XCTest
@testable import recall

final class HybridHealthTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let peripheral = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private func sleep(_ values: [UInt8], minute: UInt8) throws -> RingSleepRecord {
        var packet = [UInt8](repeating: 0, count: 130)
        packet.replaceSubrange(0..<10, with: [0x53, 0, 0, 0x24, 0x02, 0x29, 0, minute, 0, UInt8(values.count)])
        packet.replaceSubrange(10..<(10 + values.count), with: values)
        var decoder = RingSleepHistoryDecoder()
        try decoder.append(Data(packet + [0x53, 0xff]))
        return try XCTUnwrap(decoder.records.first)
    }

    func testSleepFillsOnlyMissingAndKeepsLightAndConflictSeparate() throws {
        let records = try [sleep([1, 2], minute: 0), sleep([3, 5], minute: 4)]
        let date = try XCTUnwrap(records[0].timestamp.date(in: zone))
        let analysis = try RingSleepAnalyzer.analyze(records, timeZone: zone, mapping: .issinFirmware0750)
        let health = SleepSegment(start: date, end: date.addingTimeInterval(360), stage: "asleepCore",
            source: "Fixture Health", sourceBundleId: "fixture.health", deviceModel: nil)
        let combined = HybridSleepBuilder.merge(ring: analysis.intervals, health: [health], device: "fixture-device")
        let summary = try XCTUnwrap(HybridSleepBuilder.summary(combined))
        XCTAssertEqual(summary.total, 5)
        XCTAssertEqual(summary.light, 1)
        XCTAssertEqual(summary.core, 2)
        XCTAssertEqual(summary.deep, 1)
        XCTAssertEqual(summary.rem, 1)
        XCTAssertEqual(summary.awake, 1)
        let conflicting = try RingSleepAnalyzer.analyze(records + [sleep([3], minute: 0)],
            timeZone: zone, mapping: .issinFirmware0750)
        let conflictSummary = try XCTUnwrap(HybridSleepBuilder.summary(
            HybridSleepBuilder.merge(ring: conflicting.intervals, health: [health], device: "fixture-device")))
        XCTAssertEqual(conflictSummary.unknown, 1)
        XCTAssertEqual(conflictSummary.total, 4)
        XCTAssertEqual(combined.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }, 360)

        let samples = try records.map { try SmartRingSample(sleep: $0, peripheralID: peripheral,
            firmware: "0.7.5.0", timeZone: zone) }
        let baseline = HealthPayload(collectedAt: date.addingTimeInterval(600), records: [], sleep: SleepSummary(segments: [health]), workouts: nil)
        let payload = HealthDataIntegrator.combine(healthKit: baseline, ring: samples,
            collectedAt: baseline.collectedAt, deviceModelID: "issin-smart-recovery-ring")
        XCTAssertEqual(payload.sleep?.total, 5)
        XCTAssertNotNil(payload.sleepSessions?.first?.sessionID)
        XCTAssertEqual(payload.sleepSessions?.first?.clockTimeZone, "GMT")
        XCTAssertEqual(payload.sourceSleep?.segments?.count, 1)
        XCTAssertEqual(payload.sleepReplacementWindow?.start, date)
        XCTAssertEqual(payload.sleepReplacementWindow?.end, date.addingTimeInterval(360))
        let attachment = XCTAttachment(data: try HubRawEvent.encoder.encode(payload), uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-hybrid-sleep-snapshot"; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func sensor(name: String, value: Double, unit: String?, daily: Bool = false) throws -> RingSensorRecord {
        let object: [String: Any] = ["timestamp": ["year": 2024, "month": 2, "day": 29, "hour": daily ? 0 : 12, "minute": 0, "second": 0],
            "dateOnly": daily, "format": "synthetic", "measurements": [["name": name, "value": value, "unit": unit as Any? ?? NSNull()]],
            "series": [], "rawBytes": [daily ? 0x51 : 0x55, 0, 0, 1, 2, 3, 4]]
        return try JSONDecoder().decode(RingSensorRecord.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @MainActor
    func testCaptureRetriesPreserveFirstProgressAndSharedCapacity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = SmartRingCaptureArchive(root: root)
        let raw = RingRawHistory(command: RingReadCommand.hrvHistory.rawValue, notifications: [])
        let encoder = JSONEncoder()
        var captureObject: [String: Any] = ["peripheralID": peripheral.uuidString, "command": RingReadCommand.hrvHistory.rawValue,
            "attempted": true, "startedAt": 0, "transferComplete": false,
            "raw": try JSONSerialization.jsonObject(with: encoder.encode(raw)), "unexpectedNotifications": [],
            "decoded": try JSONSerialization.jsonObject(with: encoder.encode(RingHistoryCodec.decode(raw)))]
        func capture() throws -> RingHistoryCapture {
            try JSONDecoder().decode(RingHistoryCapture.self, from: JSONSerialization.data(withJSONObject: captureObject))
        }
        try archive.save(capture(), capturedAt: Date(timeIntervalSince1970: 1), timeZone: zone, existingObservationCount: 9999)
        captureObject["startedAt"] = 10
        try archive.save(capture(), capturedAt: Date(timeIntervalSince1970: 2), timeZone: zone, existingObservationCount: 9999)
        XCTAssertEqual(try archive.count(), 1)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(saved["capturedAt"] as? Double, Date(timeIntervalSince1970: 1).timeIntervalSinceReferenceDate)
        let snapshotObject: [String: Any] = ["peripheralID": peripheral.uuidString, "capturedAt": 0,
            "info": ["firmware": "0.7.5.0", "batteryPercent": 50], "histories": [captureObject]]
        let snapshot = try JSONDecoder().decode(RingHistorySnapshot.self,
            from: JSONSerialization.data(withJSONObject: snapshotObject))
        XCTAssertThrowsError(try archive.saveContext(snapshot, timeZone: zone, existingObservationCount: 9999))
        XCTAssertEqual(try archive.count(), 1)
    }

    func testSensorsPreferKnownUnitsWithoutInventingTimesOrReplacingUnknownModel() throws {
        let pulse = try SmartRingSample(sensor: sensor(name: "heartRate", value: 66, unit: "bpm"),
            command: .spotHeartRateHistory, peripheralID: peripheral, firmware: "0.7.5.0", timeZone: zone)
        let oxygen = try SmartRingSample(sensor: sensor(name: "oxygenSaturation", value: 96, unit: "%"),
            command: .oxygenHistory, peripheralID: peripheral, firmware: "0.7.5.0", timeZone: zone)
        let temperature = try SmartRingSample(sensor: sensor(name: "temperatureSDKValue", value: 35, unit: nil),
            command: .temperatureHistory, peripheralID: peripheral, firmware: "0.7.5.0", timeZone: zone)
        let steps = try SmartRingSample(sensor: sensor(name: "steps", value: 0, unit: "count", daily: true),
            command: .dailyActivityHistory, peripheralID: peripheral, firmware: "0.7.5.0", timeZone: zone)
        let now = pulse.end.addingTimeInterval(60)
        let payload = HealthDataIntegrator.combine(healthKit: nil, ring: [pulse, oxygen, temperature, steps], collectedAt: now,
            deviceModelID: "issin-smart-recovery-ring")
        XCTAssertEqual(payload.records.first { $0.metricId == HealthDataIntegrator.heartRate }?.value, 66)
        XCTAssertEqual(payload.records.first { $0.metricId == "HKQuantityTypeIdentifierOxygenSaturation" }?.value, 96)
        XCTAssertEqual(payload.records.first { $0.metricId == "smart_ring.temperatureSDKValue" }?.unit, "raw")
        let count = try XCTUnwrap(payload.records.first { $0.metricId == "HKQuantityTypeIdentifierStepCount" })
        XCTAssertEqual(count.value, 0); XCTAssertEqual(count.day, "2024-02-29"); XCTAssertEqual(count.measurementTimeBasis, "ring_day")
        XCTAssertFalse(payload.records.contains { $0.metricId.contains("BodyTemperature") })
        XCTAssertFalse(HealthDataIntegrator.combine(healthKit: nil, ring: [pulse], collectedAt: now)
            .records.contains { $0.metricId == HealthDataIntegrator.heartRate })
        XCTAssertTrue(HealthDataIntegrator.combine(healthKit: nil, ring: [pulse], collectedAt: now.addingTimeInterval(86401))
            .records.isEmpty)
        let attachment = XCTAttachment(data: try HubRawEvent.encoder.encode(payload), uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-hybrid-sensor-snapshot"; attachment.lifetime = .keepAlways; add(attachment)

        var revisedSteps = try SmartRingSample(sensor: sensor(name: "steps", value: 20, unit: "count", daily: true),
            command: .dailyActivityHistory, peripheralID: peripheral, firmware: "0.7.5.0", timeZone: zone)
        revisedSteps.capturedAt = now
        let revised = HealthDataIntegrator.combine(healthKit: nil, ring: [steps, revisedSteps], collectedAt: now,
            deviceModelID: "issin-smart-recovery-ring")
        XCTAssertEqual(revised.records.first { $0.metricId == "HKQuantityTypeIdentifierStepCount" }?.value, 20)
    }
}
