import Foundation

/// Health data summary for a time period, sent to OpenClaw via telemetry API
struct HealthSummary: Codable {
    let periodStart: Date
    let periodEnd: Date

    // Activity
    var steps: Int?
    var activeEnergyKcal: Double?
    var basalEnergyKcal: Double?
    var distanceMeters: Double?
    var flightsClimbed: Int?

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
    var bodyFatPercent: Double?
    var leanBodyMassKg: Double?
    var bmi: Double?
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
        if let v = basalEnergyKcal { parts.append("basal=\(String(format: "%.0f", v))") }
        if let v = distanceMeters { parts.append("dist=\(String(format: "%.0f", v))") }
        if let v = flightsClimbed { parts.append("flights=\(v)") }
        if let v = heartRateAvg { parts.append("hr=\(String(format: "%.0f", v))") }
        if let v = heartRateMin { parts.append("hrMin=\(String(format: "%.0f", v))") }
        if let v = heartRateMax { parts.append("hrMax=\(String(format: "%.0f", v))") }
        if let v = restingHeartRate { parts.append("resting=\(String(format: "%.0f", v))") }
        if let v = hrvAvgMs { parts.append("hrv=\(String(format: "%.0f", v))") }
        if let v = bloodOxygenPercent { parts.append("spO2=\(String(format: "%.0f", v))") }
        if let v = respiratoryRateAvg { parts.append("resp=\(String(format: "%.0f", v))") }
        if let v = bodyMassKg { parts.append("mass=\(String(format: "%.1f", v))") }
        if let v = bodyFatPercent { parts.append("bodyFat=\(String(format: "%.1f", v))%") }
        if let v = leanBodyMassKg { parts.append("lean=\(String(format: "%.1f", v))kg") }
        if let v = bmi { parts.append("bmi=\(String(format: "%.1f", v))") }
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
    /// Per-segment detail (each sleep session start/end + stage). Optional for
    /// backward compatibility; populated by the new payload path only.
    var segments: [SleepSegment]?
}

/// One contiguous sleep stage segment from HKCategorySample (sleepAnalysis).
struct SleepSegment: Codable {
    let start: Date
    let end: Date
    /// HKCategoryValueSleepAnalysis case name: "asleepREM" / "asleepDeep" / "asleepCore"
    /// / "asleepUnspecified" / "awake" / "inBed".
    let stage: String
    let source: String?
    let deviceModel: String?
}

/// Individual workout summary
struct WorkoutSummary: Codable {
    let activityType: String
    let durationSeconds: Double
    var energyKcal: Double?
    var distanceMeters: Double?
    let start: Date
    let end: Date
    var source: String?
    var deviceModel: String?
}

// MARK: - Self-describing payload (new format, parallel with HealthSummary)

/// Generic envelope for one health metric. Carries enough metadata so the
/// server can interpret value, unit, time, and provenance without a
/// hard-coded mapping table on the receiving side.
struct HealthRecord: Codable {
    /// HealthKit identifier original string, e.g. "HKQuantityTypeIdentifierBodyMass".
    let metricId: String

    /// Numeric value. Always present for quantity metrics; absent for category-only
    /// records that use `valueText`.
    let value: Double?

    /// Optional textual value (sleep stage names etc.).
    let valueText: String?

    /// Min / max for `discreteStats` aggregations (e.g. heart rate).
    let valueMin: Double?
    let valueMax: Double?

    /// Unit string in HKUnit notation: "kg" / "count" / "count/min" / "kcal" /
    /// "m" / "%" / "degC" / "ms" / etc.
    let unit: String

    /// Aggregation kind: "latest" / "cumulativeSum" / "discreteAvg" /
    /// "discreteStats" / "category".
    let aggregation: String

    /// Actual measurement time. For `latest` this is the underlying HKSample.endDate;
    /// for aggregations this equals `intervalEnd`.
    let measuredAt: Date

    /// Aggregation interval (only set for sum / avg / stats).
    let intervalStart: Date?
    let intervalEnd: Date?

    /// Number of samples that fed the aggregation.
    let sampleCount: Int?

    /// HKSource.name (e.g. "Health" for manual entries, "Apple Watch", "ISSIN ...").
    let source: String?

    /// HKDevice.model (e.g. "Watch", "iPhone", nil for manual or unknown).
    let deviceModel: String?
}

/// New self-describing health payload sent to server alongside (or replacing)
/// the legacy `HealthSummary`. Server interprets each record by `metricId` +
/// `unit` + `aggregation` rather than relying on field names.
struct HealthPayload: Codable {
    /// Time recall finished aggregating this snapshot.
    let collectedAt: Date

    /// One record per metric (latest value with measurement time).
    let records: [HealthRecord]

    /// Sleep summary with per-segment detail (when available).
    let sleep: SleepSummary?

    /// Workouts with start/end already preserved.
    let workouts: [WorkoutSummary]?
}

extension HealthPayload {
    /// Compact one-line dump for ActivityLogger. Shows count + a sample of
    /// metricId=value entries plus measuredAt for low-frequency latest items
    /// so the operator can verify the payload contains expected data.
    func recordsLogSummary() -> String {
        var parts: [String] = ["records=\(records.count)"]
        for r in records.prefix(8) {
            let id = r.metricId
                .replacingOccurrences(of: "HKQuantityTypeIdentifier", with: "")
            if let v = r.value {
                let valueStr = abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.2f", v)
                if r.aggregation == "latest" {
                    parts.append("\(id)=\(valueStr)\(r.unit)@\(r.measuredAt.formatted(.iso8601))")
                } else {
                    parts.append("\(id)=\(valueStr)\(r.unit)[\(r.aggregation)]")
                }
            }
        }
        if records.count > 8 {
            parts.append("…+\(records.count - 8)")
        }
        if let s = sleep, let total = s.total {
            parts.append("sleep=\(Int(total))m")
        }
        if let w = workouts, !w.isEmpty {
            parts.append("workouts=\(w.count)")
        }
        return parts.joined(separator: " ")
    }
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
