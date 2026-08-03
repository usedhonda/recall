import XCTest
import CoreLocation
@testable import recall

/// Regression suite for `JumpGate` — the pure speed/jump-decision logic behind
/// `LocationManager.shouldAcceptLocation`. Proves both that the original teleport
/// protection is intact and that a sustained streak recovers from anchor lockup.
final class JumpGateTests: XCTestCase {

    // Anchor fixed at the equator origin; ~0.01 deg lon is ~1113 m there, so any
    // sub-second dt implies a wildly super-human speed (> 55.6 m/s).
    private let anchorCoord = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    private let jumpCoord = CLLocationCoordinate2D(latitude: 0, longitude: 0.01)
    // ~5.5 m: a normal walking-scale step.
    private let nearCoord = CLLocationCoordinate2D(latitude: 0.00005, longitude: 0)

    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date {
        t0.addingTimeInterval(seconds)
    }

    // (1) REGRESSION: an isolated glitch fix is rejected, and a following normal
    // fix is accepted — the original teleport guard still protects.
    func testIsolatedGlitchRejectedThenNormalAccepted() {
        let glitch = JumpGate.evaluate(
            candidate: (jumpCoord, at(1)),
            anchor: (anchorCoord, t0),
            streak: 0
        )
        XCTAssertEqual(glitch.decision, .reject)
        XCTAssertEqual(glitch.streak, 1)
        XCTAssertGreaterThan(glitch.impliedSpeed, JumpGate.maxSpeed)

        // Real code does not advance the anchor on a reject, but a subsequent
        // plausible fix against a fresh anchor must be accepted and reset streak.
        let normal = JumpGate.evaluate(
            candidate: (nearCoord, at(2)),
            anchor: (anchorCoord, at(1)),
            streak: glitch.streak
        )
        XCTAssertEqual(normal.decision, .accept)
        XCTAssertEqual(normal.streak, 0)
    }

    // (2) J1: three consecutive high-speed fixes against the same stale anchor —
    // the third is accepted as real motion (streak accept), streak resets.
    func testThreeConsecutiveJumpsAcceptedAsRealMotion() {
        let r1 = JumpGate.evaluate(candidate: (jumpCoord, at(1)), anchor: (anchorCoord, t0), streak: 0)
        XCTAssertEqual(r1.decision, .reject)
        XCTAssertEqual(r1.streak, 1)

        let r2 = JumpGate.evaluate(candidate: (jumpCoord, at(2)), anchor: (anchorCoord, t0), streak: r1.streak)
        XCTAssertEqual(r2.decision, .reject)
        XCTAssertEqual(r2.streak, 2)

        let r3 = JumpGate.evaluate(candidate: (jumpCoord, at(3)), anchor: (anchorCoord, t0), streak: r2.streak)
        XCTAssertEqual(r3.decision, .streakAccept)
        XCTAssertEqual(r3.streak, 0)
    }

    // (3) Streak resets after a normal acceptance interrupts the run.
    func testStreakResetsAfterNormalAcceptance() {
        let r1 = JumpGate.evaluate(candidate: (jumpCoord, at(1)), anchor: (anchorCoord, t0), streak: 0)
        XCTAssertEqual(r1.decision, .reject)
        XCTAssertEqual(r1.streak, 1)

        // A plausible fix accepts and clears the streak.
        let ok = JumpGate.evaluate(candidate: (nearCoord, at(2)), anchor: (anchorCoord, at(1)), streak: r1.streak)
        XCTAssertEqual(ok.decision, .accept)
        XCTAssertEqual(ok.streak, 0)

        // The next jump therefore starts a fresh streak at 1, not 2.
        let r2 = JumpGate.evaluate(candidate: (jumpCoord, at(3)), anchor: (anchorCoord, at(2)), streak: ok.streak)
        XCTAssertEqual(r2.decision, .reject)
        XCTAssertEqual(r2.streak, 1)
    }

    // (4) dt >= 300 s bypasses the jump gate entirely (intl-flight guard: a stale
    // anchor makes distance/dt meaningless, so the post-arrival fix is accepted).
    func testStaleAnchorBypassesJumpGate() {
        let result = JumpGate.evaluate(
            candidate: (jumpCoord, at(400)),
            anchor: (anchorCoord, t0),
            streak: 2
        )
        XCTAssertEqual(result.decision, .accept)
        XCTAssertEqual(result.streak, 0)
    }
}
