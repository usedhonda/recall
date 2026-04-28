import Foundation

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
    let sourceBundleId: String?
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
    var sourceBundleId: String?
    var deviceModel: String?
}

// MARK: - Self-describing payload

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

    /// HKSource.bundleIdentifier (e.g. "com.apple.Health" / "cc.issin.sbm").
    /// More stable than `source` for routing decisions on the server.
    let sourceBundleId: String?

    /// HKDevice.model (e.g. "Watch", "iPhone", nil for manual or unknown).
    let deviceModel: String?
}

/// Self-describing health payload sent to server. Server interprets each
/// record by `metricId` + `unit` + `aggregation` rather than relying on
/// field names.
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
