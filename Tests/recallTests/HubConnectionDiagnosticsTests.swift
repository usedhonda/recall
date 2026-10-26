import XCTest
@testable import recall

final class HubConnectionDiagnosticsTests: XCTestCase {
    func testTimingReportsOnlyTheLastObservedPhase() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(HubRequestTiming().phase, "not_reported")
        XCTAssertEqual(HubRequestTiming(dnsStart: start).phase, "dns_started")
        let connecting = HubRequestTiming(dnsStart: start, dnsEnd: start.addingTimeInterval(0.025),
                                          connectStart: start.addingTimeInterval(0.025))
        XCTAssertEqual(connecting.phase, "connecting")
        XCTAssertEqual(connecting.dnsMilliseconds, 25)
        XCTAssertNil(connecting.connectMilliseconds, "a started connection is not a completed one")
        XCTAssertEqual(HubRequestTiming(tlsStart: start).phase, "tls_started")
        XCTAssertEqual(HubRequestTiming(requestEnd: start).phase, "request_sent")
        XCTAssertEqual(HubRequestTiming(responseStart: start).phase, "response_started")
        XCTAssertNil(HubRequestTiming(dnsStart: start, dnsEnd: start.addingTimeInterval(-1)).dnsMilliseconds)
    }

    func testEndpointIdentityIsComparableWithoutExposingTheHost() throws {
        let first = try HubIngressTransport.endpointFingerprint(URL(string: "https://fixture.example.invalid")!)
        let equivalent = try HubIngressTransport.endpointFingerprint(URL(string: "https://fixture.example.invalid/")!)
        XCTAssertEqual(first, equivalent)
        XCTAssertEqual(first.count, 64)
        XCTAssertFalse(first.contains("fixture"))
        XCTAssertNotEqual(first, try HubIngressTransport.endpointFingerprint(URL(string: "https://fixture.example.invalid:8443")!))
        XCTAssertThrowsError(try HubIngressTransport.endpointFingerprint(URL(string: "http://fixture.example.invalid")!))
        XCTAssertThrowsError(try HubIngressTransport.endpointFingerprint(URL(string: "https://fixture.example.invalid?token=fixture")!))
    }

    @MainActor
    func testBoundedRecordsMergeLateMetricsAndPersistAcrossRelaunch() throws {
        let name = "fixture-connection-diagnostics-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = HubConnectionDiagnostics(defaults: defaults)
        var lastID = UUID()
        for _ in 0..<25 {
            lastID = UUID()
            store.started(id: lastID, endpointSHA256: String(repeating: "a", count: 64))
        }
        store.completed(id: lastID, urlError: URLError.timedOut.rawValue)
        store.collected(id: lastID, timing: .init(connectStart: Date()))
        let reopened = HubConnectionDiagnostics(defaults: defaults)
        XCTAssertEqual(reopened.requests.count, 20)
        XCTAssertEqual(reopened.requests.first?.id, lastID)
        XCTAssertEqual(reopened.requests.first?.urlErrorCode, URLError.timedOut.rawValue)
        XCTAssertEqual(reopened.requests.first?.timing?.phase, "connecting")
        XCTAssertTrue(reopened.requests.first?.summary.contains("last reported phase: connecting") == true)
    }
}
