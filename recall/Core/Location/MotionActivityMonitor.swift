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
    private var isRunning = false

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
        ActivityLogger.shared.log(.location, "Motion activity updates started")
    }

    func stop() {
        guard isRunning else { return }
        manager.stopActivityUpdates()
        isRunning = false
        isMoving = true
        ActivityLogger.shared.log(.location, "Motion activity updates stopped")
    }

    private func apply(_ activity: CMMotionActivity) {
        let moving = activity.walking || activity.running || activity.cycling || activity.automotive
        let label = Self.label(for: activity)
        // Unknown / low-confidence stationary is not trusted: only a confident
        // stationary reading parks the location lane.
        let parked = activity.stationary && activity.confidence != .low && !moving
        let nextMoving = !parked

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
