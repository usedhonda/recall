import Foundation
import XCTest
@testable import recall

final class ChannelReportClockTests: XCTestCase {
    func testAcceptsGeneratedWholeSecondSourceTime() {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        let sourceTime = formatter.string(from: Date(timeIntervalSince1970: 1_757_700_000.123))

        XCTAssertFalse(sourceTime.contains("."), "reporter-generated timestamps have no fraction")
        XCTAssertNotNil(ChannelStatusSourceClock.date(from: sourceTime))
    }

    func testAcceptsFractionalPendingSourceTime() {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sourceTime = formatter.string(from: Date(timeIntervalSince1970: 1_757_700_000.123))

        XCTAssertTrue(sourceTime.contains("."), "fractional timestamps represent retained pending payloads")
        XCTAssertNotNil(ChannelStatusSourceClock.date(from: sourceTime))
    }
}
