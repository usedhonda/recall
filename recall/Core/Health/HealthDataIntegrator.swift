import Foundation

/// Selects representative health values while retaining the original source records.
enum HealthDataIntegrator {
    static let heartRate = "HKQuantityTypeIdentifierHeartRate"

    static func combine(healthKit: HealthPayload?, ring: [SmartRingSample],
                        collectedAt: Date) -> HealthPayload {
        var payload = HealthPayload(collectedAt: collectedAt, records: healthKit?.records ?? [],
                                    sleep: healthKit?.sleep, workouts: healthKit?.workouts,
                                    sleepSessions: healthKit?.sleepSessions,
                                    heartRateDays: healthKit?.heartRateDays)
        let available = ring.filter { $0.end <= collectedAt }
        guard let latest = available.max(by: { $0.end < $1.end }) else { return payload }
        func record(_ metric: String, _ value: UInt8, unit: String,
                    sample: SmartRingSample) -> HealthRecord {
            var result = HealthRecord(metricId: metric, value: Double(value), valueText: nil,
                         valueMin: nil, valueMax: nil, unit: unit, aggregation: "latest",
                         measuredAt: sample.end, intervalStart: nil, intervalEnd: nil,
                         sampleCount: 1, source: "SmartRingKit", sourceBundleId: nil,
                         deviceModel: "FFF0 ring")
            result.sourceObservationID = sample.uuid
            result.sourceDeviceID = sample.ring.deviceID
            return result
        }
        // Unknown scales stay namespaced raw quantities, never HealthKit SDNN.
        var ringRecords = [
            record("smart_ring.hrv_raw", latest.ring.hrvRaw, unit: "raw", sample: latest),
            record("smart_ring.stress_raw", latest.ring.stressRaw, unit: "raw", sample: latest)
        ]
        if let pulse = available.filter({ $0.ring.heartRateBPM > 0 }).max(by: { $0.end < $1.end }) {
            let direct = record(heartRate, pulse.ring.heartRateBPM, unit: "count/min", sample: pulse)
            ringRecords.append(direct)
            let existing = payload.records.first { $0.metricId == heartRate }
            // An aggregate's end is query time, not its latest measurement. Prefer
            // direct readings inside its interval, not historical ring readings outside it.
            let mayPreferRing = existing.map { pulse.end >= ($0.intervalStart ?? $0.measuredAt) } ?? true
            if mayPreferRing {
                payload.records.removeAll { $0.metricId == heartRate }
                payload.records.append(direct)
            }
        }
        payload.sourceRecords = (healthKit?.records ?? []) + ringRecords
        payload.records += ringRecords.filter { $0.metricId != heartRate }
        return payload
    }
}
