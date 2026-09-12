import XCTest
@testable import recall

/// The position POST is a contract with the server: the greeting pipeline joins
/// `fix_id` across events and positions, and dedupes on `id`. Both spellings, and
/// the fact that they are two separate fields, are pinned down here.
final class TelemetrySampleEncodingTests: XCTestCase {
    private func encodedKeys(_ sample: TelemetrySample) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sample)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sample(id: String, fixId: String?) -> TelemetrySample {
        TelemetrySample(
            id: id,
            lat: 35.6625,
            lon: 139.6702,
            accuracy: 9,
            altitude: 32,
            speed: 0,
            timestamp: Date(timeIntervalSince1970: 1_757_700_000),
            quality: "good",
            fixId: fixId,
            wifi: "home",
            wifiSSID: "FreakOut",
            wifiSSIDAgeSeconds: 42,
            wifiConnected: true
        )
    }

    func testFixIdTravelsAsSnakeCase() throws {
        let json = try encodedKeys(sample(id: "post-1", fixId: "fix-1"))

        XCTAssertEqual(json["fix_id"] as? String, "fix-1")
        XCTAssertNil(json["fixId"], "the server reads fix_id; fixId would be silently ignored")
    }

    func testExistingWireKeysAreUnchanged() throws {
        let json = try encodedKeys(sample(id: "post-1", fixId: "fix-1"))

        for key in ["id", "lat", "lon", "accuracy", "altitude", "speed", "timestamp",
                    "quality", "wifi", "wifiSSID", "wifiSSIDAgeSeconds", "wifiConnected"] {
            XCTAssertNotNil(json[key], "\(key) disappeared from the position POST")
        }
    }

    func testHeartbeatRepeatsTheFixButNotThePostId() throws {
        // A parked phone re-sends one accepted fix every 5 min. If both POSTs carried the
        // same `id` the server would dedupe the heartbeat away and call the stream stale.
        let first = try encodedKeys(sample(id: "post-1", fixId: "fix-1"))
        let second = try encodedKeys(sample(id: "post-2", fixId: "fix-1"))

        XCTAssertNotEqual(first["id"] as? String, second["id"] as? String)
        XCTAssertEqual(first["fix_id"] as? String, second["fix_id"] as? String)
    }

    func testFixIdIsOmittedBeforeAnyFixIsAccepted() throws {
        let json = try encodedKeys(sample(id: "post-1", fixId: nil))

        XCTAssertNil(json["fix_id"], "no invented id: the server treats absence as unknown")
    }
}
