import XCTest
@testable import recall

/// Cadence policy: GPS speed owns the fast tier, motion owns walking vs parked.
final class LocationCadenceTests: XCTestCase {
    func testDepartureWindowIsFiniteAndOnlyAcceptsNewFixes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var window = LocationDepartureWindow()
        XCTAssertFalse(window.isActive(at: start))
        XCTAssertTrue(window.start(at: start))
        XCTAssertFalse(window.start(at: start.addingTimeInterval(30)))
        XCTAssertEqual(window.startedAt, start)
        XCTAssertFalse(window.acceptsNewFix(at: start, now: start.addingTimeInterval(1)))
        XCTAssertTrue(window.acceptsNewFix(at: start.addingTimeInterval(1), now: start.addingTimeInterval(2)))
        window.noteSent(fixAt: start.addingTimeInterval(1), now: start.addingTimeInterval(2))
        XCTAssertFalse(window.acceptsNewFix(at: start.addingTimeInterval(1), now: start.addingTimeInterval(3)))
        XCTAssertTrue(window.acceptsNewFix(at: start.addingTimeInterval(2), now: start.addingTimeInterval(3)))
        XCTAssertFalse(window.acceptsNewFix(at: start.addingTimeInterval(4), now: start.addingTimeInterval(3)))
        XCTAssertTrue(window.isActive(at: start.addingTimeInterval(179)))
        XCTAssertFalse(window.isActive(at: start.addingTimeInterval(180)))
        XCTAssertFalse(window.isActive(at: start.addingTimeInterval(-1)))
        XCTAssertEqual(LocationDepartureWindow.sendInterval, 10)
        window.cancel()
        XCTAssertNil(window.startedAt)
        XCTAssertNil(window.lastSentFixAt)
    }

    func testWiFiObservationsCannotCrossConnectionGenerations() {
        var connection = WiFiConnectionGeneration()
        let beforeJoin = connection.generation
        connection.update(isConnected: true)
        let first = connection.generation
        XCTAssertFalse(connection.observe(ssid: "fixture-home", generation: beforeJoin))
        XCTAssertTrue(connection.observe(ssid: "fixture-home", generation: first))
        connection.update(isConnected: true)
        XCTAssertEqual(connection.generation, first)
        XCTAssertEqual(connection.ssid, "fixture-home")
        connection.update(isConnected: false)
        XCTAssertNil(connection.ssid)
        XCTAssertFalse(connection.observe(ssid: "fixture-home", generation: first))
        connection.update(isConnected: true)
        XCTAssertFalse(connection.observe(ssid: "fixture-home", generation: first))
        XCTAssertFalse(connection.observe(ssid: "", generation: connection.generation))
        XCTAssertTrue(connection.observe(ssid: "fixture-work", generation: connection.generation))
    }

    func testFastSpeedEntersFastTierEvenWhenMotionSaysStill() {
        // A train or a smooth car can read as stationary to the motion chip.
        let tier = LocationCadencePolicy.tier(
            speed: 60,
            motionSaysMoving: false,
            secondsSinceLastMovement: 3600
        )
        XCTAssertEqual(tier, .fast)
        XCTAssertEqual(LocationCadencePolicy.sendInterval(for: tier), 30)
    }

    func testMotionWalkingKeepsWalkingTierWithoutSpeed() {
        let tier = LocationCadencePolicy.tier(
            speed: nil,
            motionSaysMoving: true,
            secondsSinceLastMovement: 3600
        )
        XCTAssertEqual(tier, .walking)
    }

    func testParkedOnlyAfterGraceWithNoSpeedAndNoMotion() {
        let stillInGrace = LocationCadencePolicy.tier(
            speed: 0.1,
            motionSaysMoving: false,
            secondsSinceLastMovement: 60
        )
        XCTAssertEqual(stillInGrace, .walking)

        let parked = LocationCadencePolicy.tier(
            speed: 0.1,
            motionSaysMoving: false,
            secondsSinceLastMovement: 300
        )
        XCTAssertEqual(parked, .parked)
        XCTAssertEqual(LocationCadencePolicy.sendInterval(for: parked), 300)
    }

    func testCoarseFixSpeedIsNotTrusted() {
        // The first fix after GPS resumes can claim a wild speed while the phone is still.
        XCTAssertNil(LocationCadencePolicy.trustedSpeed(fixSpeed: 23.3, horizontalAccuracy: 1414))
        XCTAssertEqual(LocationCadencePolicy.trustedSpeed(fixSpeed: 23.3, horizontalAccuracy: 12), 23.3)
        XCTAssertNil(LocationCadencePolicy.trustedSpeed(fixSpeed: -1, horizontalAccuracy: 12))
    }

    func testSlowWalkSpeedCountsAsMovingWithoutMotionPermission() {
        let tier = LocationCadencePolicy.tier(
            speed: 1.2,
            motionSaysMoving: false,
            secondsSinceLastMovement: 3600
        )
        XCTAssertEqual(tier, .walking)
    }
}
