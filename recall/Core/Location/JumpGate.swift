import Foundation
import CoreLocation

/// Pure, testable jump-decision logic for `LocationManager`'s speed filter.
///
/// A single glitch fix that implies an impossible speed is rejected (the
/// original intl-flight / teleport guard). But a *sustained* streak of such
/// rejections means the anchor is stale and the motion is real: coarse
/// home-reading fixes kept refreshing the anchor while genuine walking fixes
/// were rejected with escalating implied speeds. So the Nth consecutive
/// rejection is accepted as real motion and the streak resets.
struct JumpGate {
    /// Implied speed (m/s) above this within `window` is treated as a jump.
    /// 55.6 m/s == 200 km/h.
    static let maxSpeed: CLLocationSpeed = 55.6
    /// The jump guard only applies inside this window (seconds). A stale anchor
    /// (`dt >= window`, or `dt <= 0`) makes distance/dt meaningless, so it
    /// bypasses the gate — preserving the intl-flight guard behaviour.
    static let window: TimeInterval = 300
    /// Consecutive jump rejections that flip to acceptance as real motion.
    static let streakLimit = 3

    enum Decision: Equatable {
        /// Normal acceptance (speed OK, or gate bypassed). Streak resets to 0.
        case accept
        /// Jump rejected. Streak incremented.
        case reject
        /// Sustained jump streak accepted as real motion. Streak resets to 0.
        case streakAccept
    }

    struct Result: Equatable {
        let decision: Decision
        /// Updated consecutive-reject count to store back on the manager.
        let streak: Int
        /// Implied speed (m/s) for logging. 0 when the gate did not apply.
        let impliedSpeed: CLLocationSpeed
    }

    /// Evaluate a candidate fix against the last accepted anchor.
    static func evaluate(
        candidate: (coordinate: CLLocationCoordinate2D, timestamp: Date),
        anchor: (coordinate: CLLocationCoordinate2D, timestamp: Date),
        streak: Int
    ) -> Result {
        let dt = candidate.timestamp.timeIntervalSince(anchor.timestamp)
        guard dt > 0 && dt < window else {
            return Result(decision: .accept, streak: 0, impliedSpeed: 0)
        }

        let candidateLoc = CLLocation(latitude: candidate.coordinate.latitude,
                                      longitude: candidate.coordinate.longitude)
        let anchorLoc = CLLocation(latitude: anchor.coordinate.latitude,
                                   longitude: anchor.coordinate.longitude)
        let speed = candidateLoc.distance(from: anchorLoc) / dt

        guard speed > maxSpeed else {
            return Result(decision: .accept, streak: 0, impliedSpeed: speed)
        }

        // A jump. Isolated glitches don't persist, so reject and count. But a
        // sustained streak means the anchor is stale and the motion is real —
        // accept the Nth consecutive jump and reset the streak.
        let newStreak = streak + 1
        if newStreak >= streakLimit {
            return Result(decision: .streakAccept, streak: 0, impliedSpeed: speed)
        }
        return Result(decision: .reject, streak: newStreak, impliedSpeed: speed)
    }
}
