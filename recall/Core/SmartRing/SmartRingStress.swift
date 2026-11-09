import Foundation
import SmartRingKit

/// An experimental heart-rate proxy, never a measured or vendor stress score.
struct SmartRingStressEstimate: Codable {
    let method = "heart-rate-median-mad-v1"
    let unit = "personal_mad"
    let validity = "experimental_unvalidated"
    let maximumAgeSeconds: Double = 1800
    let minimumReferenceSamples = 24
    let limitations = ["heart_rate_only", "activity_not_corrected", "sleep_not_corrected",
                        "not_vendor_score", "not_probability"]
    let sourceDeviceID: String
    let firmware: String
    let clockTimeZone: String
    let estimatedAt: Date
    var inputMeasuredAt: Date?
    var inputAvailableAt: Date?
    var sourceObservationID: String?
    var baseline: RingHeartRateReference?
    var baselineObservationDigest: String?
    var status = "unavailable"
    var reason: String? = "missing_heart_rate"
    var value: Double?
}

enum SmartRingStress {
    static func evaluate(_ received: [SmartRingSample], deviceID: String, firmware: String,
                         timeZone: TimeZone, at now: Date) throws -> SmartRingStressEstimate {
        var result = SmartRingStressEstimate(sourceDeviceID: deviceID, firmware: firmware,
            clockTimeZone: timeZone.identifier, estimatedAt: now)
        // Use only independently received spot HR, never HRV/fatigue or invented RR intervals.
        let samples = received.filter {
            $0.type == "smart_ring.sensor.85" && $0.ring.deviceID == deviceID &&
            $0.ring.firmware == firmware && $0.ring.clockTimeZone == timeZone.identifier &&
            $0.start <= now && $0.availableAt.map { $0 <= now } == true
        }
        let window = DateInterval(start: now.addingTimeInterval(-7 * 86400), end: now)
        let histories = samples.map {
            RingHistoryCodec.decode(RingRawHistory(command: 0x55, notifications: [$0.ring.rawBytes]))
        }
        let features = try RingStressInputs.assemble(histories, at: now, timeZone: timeZone,
            maximumAge: result.maximumAgeSeconds, referenceWindow: window)
        result.baseline = features.heartRateReference
        guard let current = features.contexts.first(where: { $0.command == 0x55 }) else { return result }
        result.inputMeasuredAt = current.recordedAt
        guard !current.isConflicting else { result.reason = "conflicting_heart_rate"; return result }
        if let source = samples.first(where: { $0.start == current.recordedAt }) {
            result.sourceObservationID = source.uuid
            result.inputAvailableAt = source.availableAt
        }
        guard current.withinAgeLimit else { result.reason = "stale_heart_rate"; return result }
        guard let baseline = result.baseline, baseline.sampleCount >= result.minimumReferenceSamples else {
            result.reason = "insufficient_reference"; return result
        }
        let reference = Dictionary(grouping: samples.filter {
            $0.start >= window.start && $0.start < current.recordedAt
        }, by: \.start).values.compactMap { rows -> String? in
            guard rows.count == 1, let row = rows.first,
                  row.sensor?.measurements.contains(where: {
                      $0.name == "heartRate" && $0.unit == "bpm" && $0.value.isFinite && $0.value > 0
                  }) == true else { return nil }
            return row.uuid
        }
        result.baselineObservationDigest = SmartRingSample.hash(Data(reference.sorted().joined(separator: "|").utf8))
        guard let value = baseline.normalizedDifference, value.isFinite else {
            result.reason = "zero_or_unusable_dispersion"; return result
        }
        // Signed deviation: zero is the personal median, not an absence of stress.
        result.value = value
        result.status = "estimated"
        result.reason = nil
        return result
    }
}
