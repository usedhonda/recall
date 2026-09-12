import Foundation

/// How often the location lane reports, decided from GPS speed plus the motion
/// coprocessor's walking/parked answer.
enum LocationCadence: String {
    /// Phone sitting still: heartbeat only, continuous GPS off.
    case parked
    /// On foot (or motion is unsure): send on displacement, GPS continuous.
    case walking
    /// Vehicle / train: send on a short fixed interval so the track stays drawable.
    case fast
}

enum LocationCadencePolicy {
    /// 5 m/s (18 km/h) — above any walk or slow cycle, so a car pulling away switches at once.
    static let fastSpeed: Double = 5
    /// 0.7 m/s — a slow walk. Below this GPS jitter dominates.
    static let movingSpeed: Double = 0.7
    /// Stay in `walking` this long after the last real movement before parking.
    static let parkedGrace: TimeInterval = 120
    /// Heartbeat while parked or walking; movement itself drives the sends in `walking`.
    static let slowSendInterval: TimeInterval = 300
    /// Fixed cadence once moving fast (owner's call): 30 s. At 250 km/h that is a
    /// point roughly every 2 km; entering this tier is driven by GPS speed, not motion.
    static let fastSendInterval: TimeInterval = 30

    /// A fix coarser than this cannot be trusted for speed — the first fix after GPS
    /// resumes often reports a wild speed (a 23 m/s reading briefly flipped the tier
    /// to `fast` while the phone sat on a desk).
    static let speedTrustAccuracy: Double = 50

    /// Speed to judge the tier with, or nil when the fix is too coarse to believe.
    static func trustedSpeed(fixSpeed: Double, horizontalAccuracy: Double) -> Double? {
        guard fixSpeed >= 0, horizontalAccuracy >= 0, horizontalAccuracy <= speedTrustAccuracy else { return nil }
        return fixSpeed
    }

    /// `speed` is metres/second from the fix (or derived from displacement); nil when unknown.
    static func tier(
        speed: Double?,
        motionSaysMoving: Bool,
        secondsSinceLastMovement: TimeInterval
    ) -> LocationCadence {
        if let speed, speed >= fastSpeed { return .fast }
        if motionSaysMoving { return .walking }
        if let speed, speed >= movingSpeed { return .walking }
        if secondsSinceLastMovement < parkedGrace { return .walking }
        return .parked
    }

    static func sendInterval(for cadence: LocationCadence) -> TimeInterval {
        cadence == .fast ? fastSendInterval : slowSendInterval
    }
}
