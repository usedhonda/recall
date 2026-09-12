import XCTest
@testable import recall

/// Cadence policy: GPS speed owns the fast tier, motion owns walking vs parked.
final class LocationCadenceTests: XCTestCase {
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

    func testSlowWalkSpeedCountsAsMovingWithoutMotionPermission() {
        let tier = LocationCadencePolicy.tier(
            speed: 1.2,
            motionSaysMoving: false,
            secondsSinceLastMovement: 3600
        )
        XCTAssertEqual(tier, .walking)
    }
}
