import CoreMotion
import Foundation
import Observation

@Observable
@MainActor
final class MotionActivityManager {
    private let activityManager = CMMotionActivityManager()
    private let queue = OperationQueue()

    private(set) var isEnabled = false
    private(set) var currentActivity: String = "unknown"
    private(set) var currentConfidence: String = "low"
    private(set) var lastUpdate: Date?

    var isAvailable: Bool {
        CMMotionActivityManager.isActivityAvailable()
    }

    func restoreSettings() {
        let wasEnabled = AppSettings.shared.motionEnabled
        if wasEnabled && isAvailable {
            isEnabled = true
            start()
        }
    }

    func start() {
        guard isAvailable else {
            ActivityLogger.shared.log(.telemetry, "MotionActivity: not available on this device")
            return
        }

        queue.qualityOfService = .utility
        activityManager.startActivityUpdates(to: queue) { [weak self] activity in
            guard let activity else { return }
            let activityName = Self.activityName(from: activity)
            let confidence = Self.confidenceName(from: activity.confidence)
            Task { @MainActor [weak self] in
                self?.currentActivity = activityName
                self?.currentConfidence = confidence
                self?.lastUpdate = activity.startDate
            }
        }

        isEnabled = true
        ActivityLogger.shared.log(.telemetry, "MotionActivity: started")
    }

    func stop() {
        activityManager.stopActivityUpdates()
        isEnabled = false
        ActivityLogger.shared.log(.telemetry, "MotionActivity: stopped")
    }

    var snapshot: MotionActivitySnapshot? {
        guard isEnabled, let lastUpdate else { return nil }
        return MotionActivitySnapshot(
            activity: currentActivity,
            confidence: currentConfidence,
            timestamp: lastUpdate
        )
    }

    private static func activityName(from activity: CMMotionActivity) -> String {
        if activity.walking { return "walking" }
        if activity.running { return "running" }
        if activity.automotive { return "automotive" }
        if activity.cycling { return "cycling" }
        if activity.stationary { return "stationary" }
        return "unknown"
    }

    private static func confidenceName(from confidence: CMMotionActivityConfidence) -> String {
        switch confidence {
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        @unknown default: return "low"
        }
    }
}

struct MotionActivitySnapshot: Encodable {
    let activity: String
    let confidence: String
    let timestamp: Date
}
