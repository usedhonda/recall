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

extension HealthSummary {
    /// Compact list of non-nil keys with values, for payload dump logging.
    /// Used to verify what recall actually sent to the server.
    func nonNilKeysSummary() -> String {
        var parts: [String] = []
        if let v = steps { parts.append("steps=\(v)") }
        if let v = activeEnergyKcal { parts.append("kcal=\(String(format: "%.0f", v))") }
        if let v = distanceMeters { parts.append("dist=\(String(format: "%.0f", v))") }
        if let v = heartRateAvg { parts.append("hr=\(String(format: "%.0f", v))") }
        if let v = heartRateMin { parts.append("hrMin=\(String(format: "%.0f", v))") }
        if let v = heartRateMax { parts.append("hrMax=\(String(format: "%.0f", v))") }
        if let v = restingHeartRate { parts.append("resting=\(String(format: "%.0f", v))") }
        if let v = hrvAvgMs { parts.append("hrv=\(String(format: "%.0f", v))") }
        if let v = bloodOxygenPercent { parts.append("spO2=\(String(format: "%.0f", v))") }
        if let v = respiratoryRateAvg { parts.append("resp=\(String(format: "%.0f", v))") }
        if let v = bodyMassKg { parts.append("mass=\(String(format: "%.1f", v))") }
        if let v = bodyTemperatureCelsius { parts.append("bodyTemp=\(String(format: "%.1f", v))") }
        if let v = wristTemperatureCelsius { parts.append("wristTemp=\(String(format: "%.1f", v))") }
        if let s = sleepMinutes, let t = s.total { parts.append("sleep=\(String(format: "%.0f", t))m") }
        if let w = workouts, !w.isEmpty { parts.append("workouts=\(w.count)") }
        return parts.isEmpty ? "none" : parts.joined(separator: " ")
    }
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
