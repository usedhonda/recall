import XCTest
@testable import recall

final class TelemetryAcknowledgmentTests: XCTestCase {
    func testHealthRequiresExplicitAcknowledgement() throws {
        let data = Data(#"{"received":0,"healthReceived":true,"nextMinIntervalSec":60}"#.utf8)
        let response = try TelemetryAcknowledgment.validate(data: data, statusCode: 200, requiresHealth: true)
        XCTAssertEqual(response.healthReceived, true)
    }

    func testMissingOrFalseHealthAcknowledgementIsRejected() {
        for body in [
            #"{"received":0,"nextMinIntervalSec":60}"#,
            #"{"received":0,"healthReceived":false}"#
        ] {
            XCTAssertThrowsError(try TelemetryAcknowledgment.validate(
                data: Data(body.utf8), statusCode: 204, requiresHealth: true
            ))
        }
    }

    func testLocationMayOmitHealthAcknowledgement() throws {
        let data = Data(#"{"received":1,"nextMinIntervalSec":60}"#.utf8)
        let response = try TelemetryAcknowledgment.validate(data: data, statusCode: 200, requiresHealth: false)
        XCTAssertNil(response.healthReceived)
    }

    func testNonSuccessStatusIsRejectedBeforeDecode() {
        XCTAssertThrowsError(try TelemetryAcknowledgment.validate(
            data: Data(#"{"received":0,"healthReceived":true}"#.utf8),
            statusCode: 500,
            requiresHealth: true
        ))
    }

}
