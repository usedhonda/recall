import XCTest
@testable import recall

/// The crossing events are the fast path for the greetings, and the server validates them
/// strictly: a wrong word for a transition, or an invented fix id, is a 400 or a wrong
/// answer rather than a late one. This pins the wire shape both sides agreed on.
final class GeofenceEventPayloadTests: XCTestCase {
    private func json(_ value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func wifi(ssid: String?, fixId: String?) -> WiFiEventPayload {
        WiFiEventPayload(
            deviceId: "kana",
            transition: "left",
            ssid: ssid,
            occurredAt: "2026-09-13T00:33:44.500Z",
            fixId: fixId
        )
    }

    func testWiFiEventKeysAndVocabulary() throws {
        let body = try json(wifi(ssid: "FreakOut", fixId: "fix-1"))

        XCTAssertEqual(body["type"] as? String, "wifi_event")
        XCTAssertEqual(body["device_id"] as? String, "kana")
        // The server accepts only "joined" or "left" here — the geofence side says
        // enter/exit, and mixing the two vocabularies earns a 400.
        XCTAssertEqual(body["transition"] as? String, "left")
        XCTAssertEqual(body["ssid"] as? String, "FreakOut")
        XCTAssertEqual(body["occurred_at"] as? String, "2026-09-13T00:33:44.500Z")
        XCTAssertEqual(body["fix_id"] as? String, "fix-1")
    }

    func testUnknownFieldsAreLeftOutRatherThanInvented() throws {
        // Right after a launch nothing has been accepted yet, and iOS may never have
        // handed over the name. Absent means unknown; the server stores null for it.
        let body = try json(wifi(ssid: nil, fixId: nil))

        XCTAssertNil(body["ssid"])
        XCTAssertNil(body["fix_id"])
        XCTAssertEqual(body["transition"] as? String, "left")
    }

    func testGeofenceEventKeysAndVocabulary() throws {
        let body = try json(GeofenceEventPayload(
            deviceId: "kana",
            anchor: "home",
            transition: "exit",
            occurredAt: "2026-09-13T00:11:22.345Z",
            accuracyM: 12.5,
            fixId: nil
        ))

        XCTAssertEqual(body["type"] as? String, "geofence_event")
        XCTAssertEqual(body["anchor"] as? String, "home")
        XCTAssertEqual(body["transition"] as? String, "exit")
        XCTAssertEqual(body["accuracy_m"] as? Double, 12.5)
        XCTAssertNil(body["fix_id"])
    }

    func testOccurredAtCarriesMillisecondsAndZ() {
        let stamp = ISO8601DateFormatter.geofence.string(
            from: Date(timeIntervalSince1970: 1_757_724_824.5)
        )

        // The server parses this as an instant, so the exact spelling may drift — but it
        // must stay a fractional-second UTC stamp, not a whole second in local time.
        XCTAssertTrue(stamp.hasSuffix("Z"), stamp)
        XCTAssertTrue(stamp.contains(".5"), stamp)
    }
}
