import Foundation

/// Health data summary for a time period, sent to OpenClaw via telemetry API
struct HealthSummary: Codable {
    let periodStart: Date
    let periodEnd: Date

    // Activity
    var steps: Int?
    var activeEnergyKcal: Double?
    var distanceMeters: Double?

    // Heart
    var heartRateAvg: Double?
    var heartRateMin: Double?
    var heartRateMax: Double?
    var restingHeartRate: Double?
    var hrvAvgMs: Double?

    // Vitals
    var bloodOxygenPercent: Double?
    var respiratoryRateAvg: Double?

    // Body
    var bodyMassKg: Double?
    var bodyTemperatureCelsius: Double?
    var wristTemperatureCelsius: Double?

    // Sleep
    var sleepMinutes: SleepSummary?

    // Workouts
    var workouts: [WorkoutSummary]?
}

/// Sleep stage breakdown in minutes
struct SleepSummary: Codable {
    var total: Double?
    var rem: Double?
    var deep: Double?
    var core: Double?
    var awake: Double?
}

/// Individual workout summary
struct WorkoutSummary: Codable {
    let activityType: String
    let durationSeconds: Double
    var energyKcal: Double?
    var distanceMeters: Double?
    let start: Date
    let end: Date
}

/// Result of health data send attempt
enum HealthSendResult {
    case none
    case sending
    case sent(status: Int, body: String)
    case error(String)

    var isSent: Bool {
        if case .sent = self { return true }
        return false
    }

    var isSending: Bool {
        if case .sending = self { return true }
        return false
    }
}
