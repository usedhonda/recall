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

/// One sleep period from one source. Rebuilt from HealthKit on every snapshot, so a
/// night the source wrote days late still arrives. Identity for a reader: `start` +
/// `sourceBundleId`; a later snapshot supersedes an earlier one.
struct SleepSession: Codable, Equatable {
    let start: Date
    let end: Date
    /// Time asleep, with overlapping samples counted once.
    let totalMinutes: Double
    let remMinutes: Double
    let deepMinutes: Double
    let coreMinutes: Double
    let awakeMinutes: Double
    let source: String?
    let sourceBundleId: String?
    let sampleCount: Int
}

/// Heart rate for one local calendar day.
struct HeartRateDay: Codable, Equatable {
    /// yyyy-MM-dd in `timeZone`.
    let day: String
    let timeZone: String
    let avg: Double
    let min: Double
    let max: Double
}

/// One sleepAnalysis sample, reduced to what session grouping needs.
struct SleepSampleInput: Equatable {
    let start: Date
    let end: Date
    /// Same names as `SleepSegment.stage`.
    let stage: String
    let source: String?
    let sourceBundleId: String?
}

enum SleepSessionBuilder {
    /// A gap this long separates two sleep periods.
    static let sessionGap: TimeInterval = 3 * 3600

    /// HealthKit returns every sample from every source and never merges them, so each
    /// source is grouped apart and overlaps are counted once. `inBed` is not sleep and
    /// does not extend a session.
    static func sessions(from samples: [SleepSampleInput]) -> [SleepSession] {
        let used = samples.filter { $0.stage != "inBed" && $0.end > $0.start }
        let bySource = Dictionary(grouping: used) { $0.sourceBundleId ?? $0.source ?? "" }
        var result: [SleepSession] = []
        for sourceSamples in bySource.values {
            var current: [SleepSampleInput] = []
            var currentEnd = Date.distantPast
            for sample in sourceSamples.sorted(by: { $0.start < $1.start }) {
                if !current.isEmpty, sample.start.timeIntervalSince(currentEnd) >= sessionGap {
                    result.append(session(current))
                    current = []
                    currentEnd = .distantPast
                }
                current.append(sample)
                currentEnd = max(currentEnd, sample.end)
            }
            if !current.isEmpty { result.append(session(current)) }
        }
        return result.sorted { $0.start < $1.start }
    }

    private static let asleepStages: Set<String> = ["asleepREM", "asleepDeep", "asleepCore", "asleepUnspecified"]

    private static func session(_ samples: [SleepSampleInput]) -> SleepSession {
        func minutes(_ stages: Set<String>) -> Double {
            var total: TimeInterval = 0
            var coveredUntil = Date.distantPast
            for sample in samples where stages.contains(sample.stage) {
                let start = max(sample.start, coveredUntil)
                if sample.end > start {
                    total += sample.end.timeIntervalSince(start)
                    coveredUntil = sample.end
                }
            }
            return total / 60
        }
        return SleepSession(
            start: samples[0].start,
            end: samples.map(\.end).max() ?? samples[0].end,
            totalMinutes: minutes(asleepStages),
            remMinutes: minutes(["asleepREM"]),
            deepMinutes: minutes(["asleepDeep"]),
            coreMinutes: minutes(["asleepCore"]),
            awakeMinutes: minutes(["awake"]),
            source: samples[0].source,
            sourceBundleId: samples[0].sourceBundleId,
            sampleCount: samples.count
        )
    }
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
    /// Identity of this logical aggregate delivery. Retries reuse the value;
    /// a new aggregate instance receives a new UUID. Kept out of legacy JSON.
    let deliveryID: UUID = UUID()
    /// Time recall finished aggregating this snapshot.
    let collectedAt: Date

    /// One record per metric (latest value with measurement time).
    let records: [HealthRecord]

    /// Sleep summary with per-segment detail (when available).
    let sleep: SleepSummary?

    /// Workouts with start/end already preserved.
    let workouts: [WorkoutSummary]?

    /// Sleep periods from the last `HealthKitManager.historyDays` days.
    var sleepSessions: [SleepSession]? = nil

    /// Heart rate per local day for the same period.
    var heartRateDays: [HeartRateDay]? = nil

    enum CodingKeys: String, CodingKey {
        case collectedAt, records, sleep, workouts, sleepSessions, heartRateDays
    }
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

enum HealthUploadSource: String, Codable {
    case hub
    case legacy
}

enum HealthUploadOutcome {
    case acknowledged(deliveryID: UUID, source: HealthUploadSource)
    case scheduled(deliveryID: UUID)
    case failed(deliveryID: UUID, message: String)
}
