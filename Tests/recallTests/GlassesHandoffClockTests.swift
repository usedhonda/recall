import Foundation
import XCTest
@testable import recall

@MainActor
final class GlassesHandoffClockTests: XCTestCase {
    func testParsesWholeSecondISO8601CaptureClock() {
        let date = GlassesHandoffReceiver.parseCaptureDate("2026-10-03T12:34:56Z")

        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_791_030_896))
    }

    func testParsesFractionalSecondISO8601CaptureClock() {
        guard let date = GlassesHandoffReceiver.parseCaptureDate("2026-10-03T12:34:56.789Z") else {
            return XCTFail("fractional ISO-8601 capture clock should parse")
        }

        XCTAssertEqual(date.timeIntervalSince1970, 1_791_030_896.789, accuracy: 0.001)
    }

    func testRejectsMalformedCaptureClock() {
        XCTAssertNil(GlassesHandoffReceiver.parseCaptureDate("not-a-timestamp"))
    }
}
