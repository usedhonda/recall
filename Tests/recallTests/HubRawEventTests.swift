import XCTest
@testable import recall

final class HubRawEventTests: XCTestCase {
    func testTheSameBatchKeepsItsIdentityAndADifferentOneDoesNot() {
        let items = [Data("{\"a\":1}".utf8), Data("{\"a\":2}".utf8)]
        let payload = HubRawEvent.sourcePayload(items: items, deleted: ["x"])
        XCTAssertEqual(String(data: payload, encoding: .utf8), "{\"deleted\":[\"x\"],\"items\":[{\"a\":1},{\"a\":2}]}")
        let time = Date(timeIntervalSince1970: 1)
        XCTAssertEqual(HubRawEvent.observationID(for: payload, occurredAt: time),
                       HubRawEvent.observationID(for: HubRawEvent.sourcePayload(items: items, deleted: ["x"]), occurredAt: time))
        XCTAssertNotEqual(HubRawEvent.observationID(for: payload, occurredAt: time),
                          HubRawEvent.observationID(for: payload, occurredAt: time.addingTimeInterval(1)))
    }

    func testABatchFitsAndIsAcceptedByTheProducerContract() throws {
        let item = Data("{\"uuid\":\"00000000-0000-0000-0000-000000000000\",\"value\":72.5}".utf8)
        let payload = HubRawEvent.sourcePayload(items: Array(repeating: item, count: HubRawStream.maxItemsPerEvent), deleted: [])
        let envelope = try HubProducerContract.makeEnvelope(
            route: .healthSamples, deviceID: "fixture-device",
            observationID: HubRawEvent.observationID(for: payload, occurredAt: Date(timeIntervalSince1970: 0)),
            occurredAt: Date(timeIntervalSince1970: 0), timeBasis: "batched_at", sourcePayloadJSON: payload
        )
        XCTAssertEqual(envelope.route.kind, "recall.health-samples.v1")
        XCTAssertEqual(envelope.route.domain, "health")
    }
}
