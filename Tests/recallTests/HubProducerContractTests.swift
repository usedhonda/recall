import Foundation
import XCTest
@testable import recall

final class HubProducerContractTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_759_000_000)

    func testCanonicalIDUsesUnpaddedUTF8Base64URL() throws {
        let id = try HubProducerContract.canonicalExternalID(route: .audioOriginal,
                                                              deviceID: "端末", observationID: "obs/1")
        XCTAssertEqual(id, "v1:audio-original:56uv5pyr:b2JzLzE")
        XCTAssertFalse(id.contains("="))
        XCTAssertFalse(id.contains("/"))
    }

    func testEnvelopePreservesSourceObjectAndOriginalBytes() throws {
        let source = Data(#"{"z":null,"n":1.25,"array":[true,"x"]}"#.utf8)
        let envelope = try HubProducerContract.makeEnvelope(route: .gpsDelivery, deviceID: "phone",
                                                              observationID: "o1", occurredAt: date,
                                                              timeBasis: "timestamp", sourcePayloadJSON: source,
                                                              originalBytes: Data("abc".utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: envelope.encodedJSON) as? [String: Any])
        XCTAssertEqual(json["source"] as? String, "recall")
        XCTAssertEqual(json["kind"] as? String, "recall.gps-delivery.v1")
        let sourceObject = try XCTUnwrap((json["metadata"] as? [String: Any])?["source_payload"] as? [String: Any])
        XCTAssertTrue(sourceObject["z"] is NSNull)
        XCTAssertEqual(sourceObject["n"] as? Double, 1.25)
        let array = try XCTUnwrap(sourceObject["array"] as? [Any])
        XCTAssertEqual(array.count, 2)
        XCTAssertEqual(array[0] as? Bool, true)
        XCTAssertEqual(array[1] as? String, "x")
        XCTAssertEqual(envelope.originalSHA256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(envelope.originalByteLength, 3)
    }

    func testSourcePayloadNumberLiteralsAreNotRounded() throws {
        let source = Data(#"{"integer":9007199254740993,"decimal":1.234567890123456789}"#.utf8)
        let envelope = try HubProducerContract.makeEnvelope(route: .wifi, deviceID: "phone",
                                                              observationID: "o2", occurredAt: date,
                                                              timeBasis: "occurred_at", sourcePayloadJSON: source)
        let wire = try XCTUnwrap(String(data: envelope.encodedJSON, encoding: .utf8))
        XCTAssertTrue(wire.contains("9007199254740993"))
        XCTAssertTrue(wire.contains("1.234567890123456789"))
    }

    func testSourcePayloadMustBeObjectAndEnvelopeHasSizeLimit() throws {
        XCTAssertThrowsError(try HubProducerContract.makeEnvelope(route: .wifi, deviceID: "d",
                                                                   observationID: "o", occurredAt: date,
                                                                   timeBasis: "occurred_at", sourcePayloadJSON: Data("[]".utf8)))
        let huge = Data((String(repeating: "x", count: 21_000_000)).utf8)
        XCTAssertThrowsError(try HubProducerContract.makeEnvelope(route: .wifi, deviceID: "d",
                                                                   observationID: "o", occurredAt: date,
                                                                   timeBasis: "occurred_at", sourcePayloadJSON: Data("{\"x\":\"".utf8) + huge + Data("\"}".utf8)))
    }

    func testReceiptRequiresExactKeysAndMatchesBinding() throws {
        let id = "123e4567-e89b-12d3-a456-426614174000"
        let data = try JSONSerialization.data(withJSONObject: [
            "receipt_version": 1, "source": "recall", "external_id": "source-id",
            "event_id": id, "sha256": NSNull(), "byte_length": 0, "ingest_sequence": 2
        ], options: [.sortedKeys])
        let expected = HubExpectedStorageReceipt(source: "recall", externalID: "source-id", sha256: nil, byteLength: 0)
        let response = try JSONSerialization.data(withJSONObject: ["status": "created", "storage_receipt":
            try XCTUnwrap(JSONSerialization.jsonObject(with: data))])
        XCTAssertEqual(try HubProducerContract.validateResponse(responseData: response, expected: expected,
                                                                  boundEventID: id).eventID, id)
        XCTAssertThrowsError(try HubProducerContract.validateResponse(responseData: response, expected: expected,
                                                                       boundEventID: "123e4567-e89b-12d3-a456-426614174001"))
        var extra = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        extra["extra"] = true
        XCTAssertThrowsError(try HubStorageReceipt.decode(JSONSerialization.data(withJSONObject: extra)))
        // Encode literal JSON: JSONSerialization would normalize Swift 2.0 to 2
        // before this test reaches the production parser.
        let validLiteral = try XCTUnwrap(String(data: data, encoding: .utf8))
        for invalidInteger in ["2.0", "2e0", "true"] {
            let invalidLiteral = validLiteral.replacingOccurrences(of: "\"ingest_sequence\":2",
                                                                   with: "\"ingest_sequence\":\(invalidInteger)")
            let invalidResponse = Data("{\"storage_receipt\":\(invalidLiteral)}".utf8)
            XCTAssertThrowsError(try HubProducerContract.validateResponse(responseData: invalidResponse, expected: expected))
        }
    }

    func testProcessingReceiptRequiresImmutableBindingAndAllowsMutableState() throws {
        let eventID = "123e4567-e89b-12d3-a456-426614174000"
        let base: [String: Any] = ["receipt_version": 1, "intent_committed": true,
            "job_id": "123e4567-e89b-12d3-a456-426614174001", "original_event_id": eventID,
            "pipeline_version": "local-stt-v1", "state": "pending"]
        let pending = try HubProcessingReceipt.decode(JSONSerialization.data(withJSONObject: base), expectedOriginalEventID: eventID)
        XCTAssertEqual(pending.state, .pending)
        var completed = base; completed["state"] = "completed"
        XCTAssertEqual(try HubProcessingReceipt.decode(JSONSerialization.data(withJSONObject: completed), expectedOriginalEventID: eventID).state, .completed)
        var changedTuple = base; changedTuple["pipeline_version"] = "other"
        XCTAssertThrowsError(try HubProcessingReceipt.decode(JSONSerialization.data(withJSONObject: changedTuple), expectedOriginalEventID: eventID))
        var missing = base; missing.removeValue(forKey: "job_id")
        XCTAssertThrowsError(try HubProcessingReceipt.decode(JSONSerialization.data(withJSONObject: missing), expectedOriginalEventID: eventID))
        var invalidJob = base; invalidJob["job_id"] = "job-1"
        XCTAssertThrowsError(try HubProcessingReceipt.decode(JSONSerialization.data(withJSONObject: invalidJob), expectedOriginalEventID: eventID))
        var uppercaseJob = base; uppercaseJob["job_id"] = "123E4567-E89B-12D3-A456-426614174001"
        XCTAssertThrowsError(try HubProcessingReceipt.decode(JSONSerialization.data(withJSONObject: uppercaseJob), expectedOriginalEventID: eventID))
        var changedEvent = base; changedEvent["original_event_id"] = "other-event"
        XCTAssertThrowsError(try HubProcessingReceipt.decode(JSONSerialization.data(withJSONObject: changedEvent), expectedOriginalEventID: eventID))
    }
}
