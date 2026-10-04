import XCTest
@testable import recall

final class AudioCaptureEvidenceTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_790_000_000)
    private let externalID = "v1:audio-original:ZGV2:Y2h1bms"

    func testStartIsTheChunkClockMinusThePrependedSamples() throws {
        let result = try XCTUnwrap(AudioCaptureEvidence.make(
            externalID: externalID, clockAtChunkStart: clock, preRollSamples: 48_000,
            lastWriteAt: clock.addingTimeInterval(5), sampleRate: 16_000))

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(formatter.date(from: result.capture["start"] as! String), clock.addingTimeInterval(-3))
        XCTAssertEqual(formatter.date(from: result.capture["end"] as! String), clock.addingTimeInterval(5))
    }

    func testShapeIsExactlyWhatTheHubAccepts() throws {
        let result = try XCTUnwrap(AudioCaptureEvidence.make(
            externalID: externalID, clockAtChunkStart: clock, preRollSamples: 0,
            lastWriteAt: clock.addingTimeInterval(2), sampleRate: 16_000))

        XCTAssertEqual(Set(result.capture.keys), ["start", "end", "status", "basis", "provenance"])
        XCTAssertEqual(result.capture["status"] as? String, "known")
        XCTAssertEqual(result.capture["basis"] as? String, "derived")
        let provenance = try XCTUnwrap(result.capture["provenance"] as? [String: Any])
        for side in ["start", "end"] {
            let evidence = try XCTUnwrap(provenance[side] as? [String: Any])
            XCTAssertEqual(Set(evidence.keys), ["basis", "source_refs", "source_fields", "method", "method_version", "precision_ms"])
            let refs = try XCTUnwrap(evidence["source_refs"] as? [[String: String]])
            XCTAssertEqual(refs, [["source": "recall", "external_id": externalID]])
            // Every named input must exist in source_payload.
            for name in try XCTUnwrap(evidence["source_fields"] as? [String]) {
                XCTAssertNotNil(result.sourceFields[name], name)
            }
        }
    }

    func testNoIntervalWithoutClockReadingsOrWhenItWouldRunBackwards() {
        XCTAssertNil(AudioCaptureEvidence.make(externalID: externalID, clockAtChunkStart: nil, preRollSamples: 0,
                                               lastWriteAt: clock, sampleRate: 16_000))
        XCTAssertNil(AudioCaptureEvidence.make(externalID: externalID, clockAtChunkStart: clock, preRollSamples: nil,
                                               lastWriteAt: clock, sampleRate: 16_000))
        XCTAssertNil(AudioCaptureEvidence.make(externalID: externalID, clockAtChunkStart: clock, preRollSamples: 0,
                                               lastWriteAt: nil, sampleRate: 16_000))
        XCTAssertNil(AudioCaptureEvidence.make(externalID: externalID, clockAtChunkStart: clock, preRollSamples: 0,
                                               lastWriteAt: clock.addingTimeInterval(-1), sampleRate: 16_000))
    }

    func testEnvelopeCarriesCaptureBesideTheUntouchedSourcePayload() throws {
        let result = try XCTUnwrap(AudioCaptureEvidence.make(
            externalID: externalID, clockAtChunkStart: clock, preRollSamples: 16_000,
            lastWriteAt: clock.addingTimeInterval(3), sampleRate: 16_000))
        var payload = ["capture_time_known": "false"]
        payload.merge(result.sourceFields) { current, _ in current }

        let envelope = try HubProducerContract.makeEnvelope(
            route: .audioOriginal, deviceID: "dev", observationID: "chunk",
            occurredAt: clock, timeBasis: "chunk_start_utc",
            sourcePayloadJSON: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
            originalBytes: Data([1, 2, 3]), capture: result.capture)

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.encodedJSON) as? [String: Any])
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual((metadata["capture"] as? [String: Any])?["status"] as? String, "known")
        XCTAssertEqual((metadata["source_payload"] as? [String: String])?["capture_time_known"], "false")
    }
}
