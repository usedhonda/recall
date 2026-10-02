import XCTest
@testable import recall

final class HubIngressTransportTests: XCTestCase {
    private final class StubProtocol: URLProtocol {
        static var respond: ((URLRequest) throws -> (Int, Data))?
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                let (status, data) = try Self.respond!(request)
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                               httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }

    override func tearDown() {
        StubProtocol.respond = nil
        super.tearDown()
    }

    private func transport() throws -> HubIngressTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return try HubIngressTransport(baseURL: URL(string: "https://hub.example.invalid")!,
                                       bearerToken: "fixture-token", configuration: configuration)
    }

    private func envelope() throws -> HubProducerEnvelope {
        try HubProducerContract.makeEnvelope(route: .gpsDelivery, deviceID: "fixture-device",
            observationID: "fixture-delivery", occurredAt: Date(timeIntervalSince1970: 1),
            timeBasis: "timestamp", sourcePayloadJSON: Data("{\"timestamp\":\"1970-01-01T00:00:01Z\"}".utf8))
    }

    func testRejectsInsecureOrCredentialBearingEndpoint() {
        for value in ["http://hub.example.invalid", "https://user:pass@hub.example.invalid",
                      "https://hub.example.invalid?token=fixture", "https://hub.example.invalid/other"] {
            XCTAssertThrowsError(try HubIngressTransport(baseURL: URL(string: value)!, bearerToken: "fixture"))
        }
        XCTAssertThrowsError(try HubIngressTransport(baseURL: URL(string: "https://hub.example.invalid")!,
                                                    bearerToken: "token\r\ninjection"))
    }

    func testCreatedAndDuplicateRequireSameMatchingReceipt() async throws {
        let event = try envelope()
        let eventID = "00000000-0000-4000-8000-000000000001"
        let response = try JSONSerialization.data(withJSONObject: ["storage_receipt": [
            "receipt_version": 1, "source": "recall", "external_id": event.externalID,
            "event_id": eventID, "sha256": NSNull(), "byte_length": 0, "ingest_sequence": 1
        ]])
        let client = try transport()
        for status in [201, 200] {
            StubProtocol.respond = { request in
                XCTAssertEqual(request.url?.path, "/v1/events")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-token")
                return (status, response)
            }
            let receipt = try await client.submit(event, boundEventID: eventID)
            XCTAssertEqual(receipt.eventID, eventID)
        }
        do {
            _ = try await client.submit(event, boundEventID: "00000000-0000-4000-8000-000000000002")
            XCTFail("Changed event binding must not acknowledge the item")
        } catch { XCTAssertEqual(error as? HubIngressTransport.Failure, .invalidResponse) }
    }

    func testLegacySuccessAndOther2xxAreNotStorageACK() async throws {
        let event = try envelope()
        let client = try transport()
        for (status, expected) in [(200, HubIngressTransport.Failure.invalidResponse), (202, .rejected(202)), (409, .rejected(409))] {
            StubProtocol.respond = { _ in (status, Data("{\"recording_id\":\"legacy\"}".utf8)) }
            do {
                _ = try await client.submit(event)
                XCTFail("No committed storage receipt")
            } catch { XCTAssertEqual(error as? HubIngressTransport.Failure, expected) }
        }
    }

    func testNetworkFailureIsBodyFreeAndDoesNotBecomeACK() async throws {
        StubProtocol.respond = { _ in throw URLError(.timedOut) }
        do {
            _ = try await transport().submit(envelope())
            XCTFail("Ambiguous response loss must remain retryable")
        } catch { XCTAssertEqual(error as? HubIngressTransport.Failure, .unavailable) }
    }
}
