import CoreMotion
import Foundation
import Observation

/// Reads iOS motion activity (the always-on motion coprocessor that also counts
/// steps) so the location lane can tell "the owner is walking" from "the phone is
/// parked on a desk". Far cheaper than keeping GPS running to answer the same
/// question; raw accelerometer/gyro streaming is deliberately not used.
///
/// Availability and permission are optional: when motion is unavailable or the
/// owner declines, `isMoving` stays true so location behaves exactly as before.
@MainActor
@Observable
final class MotionActivityMonitor {
    static let shared = MotionActivityMonitor()

    /// True unless motion says the device is sitting still. Defaults to true so a
    /// missing permission never silences the location stream.
    private(set) var isMoving = true
    /// Last time motion reported anything other than "stationary".
    private(set) var lastMotionAt = Date()
    private(set) var latestActivity = "unknown"

    /// Called when motion flips from parked to moving, so the location lane can
    /// resume GPS immediately instead of waiting for the next heartbeat.
    var onMovementStart: (() -> Void)?

    private let manager = CMMotionActivityManager()
    /// Step events are the fastest "the owner started walking" signal: the activity
    /// classifier needs several seconds of gait before it says walking, while steps
    /// show up within a couple of them. Same coprocessor, no extra sensors powered.
    private let pedometer = CMPedometer()
    private var lastStepCount = 0
    private var isRunning = false

    /// Live sensor read-outs for the HUD. Device motion is sampled only while the
    /// screen is showing them (2 Hz) — it is the one sensor here that costs power.
    private let deviceMotion = CMMotionManager()
    private(set) var stepsSinceStart = 0
    /// Steps per minute from the pedometer's own cadence estimate.
    private(set) var gaitStepsPerMinute: Double?
    private(set) var userAcceleration: Double?
    private(set) var rotationRate: Double?

    private init() {}

    var isAvailable: Bool { CMMotionActivityManager.isActivityAvailable() }

    func start() {
        guard !isRunning, isAvailable else {
            if !isAvailable {
                ActivityLogger.shared.log(.location, "Motion activity unavailable — location cadence stays always-on")
            }
            return
        }
        isRunning = true
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.apply(activity)
        }
        startStepUpdates()
        ActivityLogger.shared.log(.location, "Motion activity + step updates started")
    }

    func stop() {
        guard isRunning else { return }
        manager.stopActivityUpdates()
        pedometer.stopUpdates()
        lastStepCount = 0
        isRunning = false
        isMoving = true
        ActivityLogger.shared.log(.location, "Motion activity updates stopped")
    }

    private func startStepUpdates() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        lastStepCount = 0
        pedometer.startUpdates(from: Date()) { [weak self] data, _ in
            guard let data else { return }
            let steps = data.numberOfSteps.intValue
            let cadence = data.currentCadence?.doubleValue
            Task { @MainActor [weak self] in
                self?.gaitStepsPerMinute = cadence.map { $0 * 60 }
                self?.noteSteps(steps)
            }
        }
    }

    /// Cumulative step count since the monitor started; any increase means walking now.
    private func noteSteps(_ steps: Int) {
        stepsSinceStart = steps
        guard steps > lastStepCount else { return }
        lastStepCount = steps
        lastMotionAt = Date()
        guard !isMoving else { return }
        isMoving = true
        latestActivity = "steps"
        ActivityLogger.shared.log(.location, "Motion: steps detected (moving=true)")
        onMovementStart?()
    }

    /// Start/stop the 2 Hz accelerometer + gyro read-out. Foreground only.
    func startLiveSensors() {
        guard deviceMotion.isDeviceMotionAvailable, !deviceMotion.isDeviceMotionActive else { return }
        deviceMotion.deviceMotionUpdateInterval = 0.5
        deviceMotion.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            let a = motion.userAcceleration
            let r = motion.rotationRate
            self.userAcceleration = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            self.rotationRate = (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
        }
    }

    func stopLiveSensors() {
        guard deviceMotion.isDeviceMotionActive else { return }
        deviceMotion.stopDeviceMotionUpdates()
        userAcceleration = nil
        rotationRate = nil
    }

    private func apply(_ activity: CMMotionActivity) {
        let moving = activity.walking || activity.running || activity.cycling || activity.automotive
        let label = Self.label(for: activity)
        // The stream alternates between a real reading and "unknown" every couple of
        // seconds. Unknown carries no opinion, so the last real reading stands;
        // otherwise the lane would never settle.
        let nextMoving: Bool
        if moving {
            nextMoving = true
        } else if activity.stationary {
            nextMoving = false
        } else {
            nextMoving = isMoving
        }

        if moving { lastMotionAt = Date() }
        let startedMoving = nextMoving && !isMoving
        if label != latestActivity || nextMoving != isMoving {
            latestActivity = label
            isMoving = nextMoving
            ActivityLogger.shared.log(.location, "Motion: \(label) (moving=\(nextMoving))")
        }
        if startedMoving { onMovementStart?() }
    }

    private static func label(for activity: CMMotionActivity) -> String {
        var parts: [String] = []
        if activity.stationary { parts.append("stationary") }
        if activity.walking { parts.append("walking") }
        if activity.running { parts.append("running") }
        if activity.cycling { parts.append("cycling") }
        if activity.automotive { parts.append("automotive") }
        if activity.unknown || parts.isEmpty { parts.append("unknown") }
        let confidence: String
        switch activity.confidence {
        case .low: confidence = "low"
        case .medium: confidence = "med"
        case .high: confidence = "high"
        @unknown default: confidence = "?"
        }
        return parts.joined(separator: "+") + "/" + confidence
    }
}
