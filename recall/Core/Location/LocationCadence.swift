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

struct WiFiConnectionGeneration {
    private(set) var generation: UInt64 = 0
    private(set) var isConnected = false
    private(set) var ssid: String?

    mutating func update(isConnected: Bool) {
        guard self.isConnected != isConnected else { return }
        generation &+= 1
        self.isConnected = isConnected
        ssid = nil
    }

    mutating func observe(ssid: String, generation: UInt64) -> Bool {
        guard isConnected, self.generation == generation, !ssid.isEmpty else { return false }
        self.ssid = ssid
        return true
    }
}

struct LocationDepartureWindow {
    static let duration: TimeInterval = 180
    static let sendInterval: TimeInterval = 10
    private(set) var startedAt: Date?
    private(set) var lastSentFixAt: Date?
    /// The fix whose send is in flight. Taken before the network await so a second
    /// delivery cannot also pass as the first send; released if the send never lands.
    private(set) var reservedFixAt: Date?

    func isActive(at now: Date) -> Bool {
        guard let startedAt else { return false }
        return now >= startedAt && now.timeIntervalSince(startedAt) < Self.duration
    }

    @discardableResult
    mutating func start(at now: Date) -> Bool {
        guard !isActive(at: now) else { return false }
        startedAt = now
        lastSentFixAt = nil
        reservedFixAt = nil
        return true
    }

    mutating func cancel() {
        startedAt = nil
        lastSentFixAt = nil
        reservedFixAt = nil
    }

    func acceptsNewFix(at fixAt: Date, now: Date) -> Bool {
        guard isActive(at: now), let startedAt, fixAt > startedAt, fixAt <= now else { return false }
        return lastSentFixAt.map { fixAt > $0 } ?? true
    }

    /// Whether this fix may be sent now, and if so reserves it. While a send is in
    /// flight nothing else may go out; the first new fix of the window goes at once,
    /// later ones fall back to `fallback` (the ordinary time/distance rule).
    mutating func reserve(fixAt: Date, now: Date, fallback: Bool) -> Bool {
        guard reservedFixAt == nil, acceptsNewFix(at: fixAt, now: now) else { return false }
        guard lastSentFixAt == nil || fallback else { return false }
        reservedFixAt = fixAt
        return true
    }

    mutating func release(fixAt: Date) {
        if reservedFixAt == fixAt { reservedFixAt = nil }
    }

    mutating func noteSent(fixAt: Date, now: Date) {
        release(fixAt: fixAt)
        guard acceptsNewFix(at: fixAt, now: now) else { return }
        lastSentFixAt = fixAt
    }
}
