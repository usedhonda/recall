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
        var fractional = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fractional["ingest_sequence"] = 2.0
        let fractionalResponse = try JSONSerialization.data(withJSONObject: ["storage_receipt": fractional])
        XCTAssertThrowsError(try HubProducerContract.validateResponse(responseData: fractionalResponse, expected: expected))
    }
}
