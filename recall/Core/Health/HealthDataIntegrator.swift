import Foundation
import SmartRingKit

/// Ring preference applies to comparable measurements, never sums overlapping sources.
enum HealthDataIntegrator {
    static let heartRate = "HKQuantityTypeIdentifierHeartRate"

    static func combine(healthKit: HealthPayload?, ring: [SmartRingSample], collectedAt: Date,
                        deviceModelID: String = "") -> HealthPayload {
        var payload = HealthPayload(collectedAt: collectedAt, records: healthKit?.records ?? [],
            sleep: healthKit?.sleep, workouts: healthKit?.workouts,
            sleepSessions: healthKit?.sleepSessions, heartRateDays: healthKit?.heartRateDays)
        let available = ring.filter { $0.start <= collectedAt && $0.end >= collectedAt.addingTimeInterval(-86400) }
        var candidates: [HealthRecord] = []
        func add(_ metric: String, value: Double, unit: String, sample: SmartRingSample,
                 aggregation: String = "latest", interval: DateInterval? = nil) {
            var record = HealthRecord(metricId: metric, value: value, valueText: nil,
                valueMin: nil, valueMax: nil, unit: unit, aggregation: aggregation,
                measuredAt: sample.start, intervalStart: interval?.start, intervalEnd: interval?.end,
                sampleCount: 1, source: "SmartRingKit", sourceBundleId: nil, deviceModel: sample.deviceModel)
            record.sourceObservationID = sample.uuid
            record.sourceDeviceID = sample.ring.deviceID
            record.sourceCapturedAt = sample.capturedAt
            record.measurementTimeBasis = sample.sensor?.dateOnly == true ? "ring_day" : "ring_wall_clock"
            if sample.sensor?.dateOnly == true {
                record.day = String(format: "%04d-%02d-%02d", sample.ring.deviceTime.year,
                                    sample.ring.deviceTime.month, sample.ring.deviceTime.day)
                record.timeZone = sample.ring.clockTimeZone
            }
            candidates.append(record)
        }
        for sample in available {
            if sample.type == "smart_ring.hrv_history" {
                if let value = sample.ring.hrvRaw { add("smart_ring.hrv_raw", value: Double(value), unit: "raw", sample: sample) }
                if let value = sample.ring.stressRaw { add("smart_ring.stress_raw", value: Double(value), unit: "raw", sample: sample) }
                if let value = sample.ring.heartRateBPM, value > 0 { add(heartRate, value: Double(value), unit: "count/min", sample: sample) }
            }
            guard let sensor = sample.sensor else { continue }
            let profiled = RingDeviceProfiles.matching(deviceID: deviceModelID, firmware: sample.ring.firmware) != nil
            for measurement in sensor.measurements {
                if profiled, sample.type == "smart_ring.sensor.85", measurement.name == "heartRate",
                   measurement.unit == "bpm", measurement.value > 0 {
                    add(heartRate, value: measurement.value, unit: "count/min", sample: sample)
                } else if profiled, sample.type == "smart_ring.sensor.102", measurement.name == "oxygenSaturation",
                          measurement.unit == "%", measurement.value > 0, measurement.value <= 100 {
                    add("HKQuantityTypeIdentifierOxygenSaturation", value: measurement.value, unit: "%", sample: sample)
                } else if profiled, sensor.dateOnly, measurement.name == "steps", measurement.unit == "count",
                          let zone = TimeZone(identifier: sample.ring.clockTimeZone) {
                    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                    if let day = calendar.dateInterval(of: .day, for: sample.start) {
                    let interval = DateInterval(start: day.start, end: min(day.end, collectedAt))
                    if interval.duration > 0,
                       healthKit?.records.first(where: { $0.metricId == "HKQuantityTypeIdentifierStepCount" }).map({
                           $0.intervalStart == day.start && $0.intervalEnd.map { $0 > day.start && $0 <= day.end } == true
                       }) ?? true {
                        add("HKQuantityTypeIdentifierStepCount", value: measurement.value, unit: "count", sample: sample,
                            aggregation: "cumulativeSum", interval: interval)
                    }
                    }
                } else {
                    add("smart_ring.\(measurement.name)", value: measurement.value,
                        unit: measurement.unit ?? "raw", sample: sample)
                }
            }
        }
        if !candidates.isEmpty {
            payload.sourceRecords = (healthKit?.records ?? []) + candidates
            for metric in Set(candidates.map(\.metricId)).sorted() {
                guard let selected = candidates.filter({ $0.metricId == metric }).max(by: {
                    if $0.measuredAt != $1.measuredAt { return $0.measuredAt < $1.measuredAt }
                    return ($0.sourceCapturedAt ?? .distantPast) < ($1.sourceCapturedAt ?? .distantPast)
                }) else { continue }
                if let previous = payload.records.first(where: { $0.metricId == metric }),
                   selected.measuredAt < (previous.intervalStart ?? previous.measuredAt) { continue }
                payload.records.removeAll { $0.metricId == metric }
                payload.records.append(selected)
            }
        }
        let sleepSamples = ring.filter {
            $0.end <= collectedAt && $0.sleep != nil &&
            RingDeviceProfiles.matching(deviceID: deviceModelID, firmware: $0.ring.firmware)?.sleepMapping != nil
        }
        if let first = sleepSamples.first,
           let zone = TimeZone(identifier: first.ring.clockTimeZone),
           let mapping = RingDeviceProfiles.matching(deviceID: deviceModelID, firmware: first.ring.firmware)?.sleepMapping {
            // Do not mix historical clock interpretations or different devices in one analysis.
            let matching = sleepSamples.filter { $0.ring.deviceID == first.ring.deviceID &&
                $0.ring.clockTimeZone == first.ring.clockTimeZone && $0.ring.firmware == first.ring.firmware }
            if let analysis = try? RingSleepAnalyzer.analyze(matching.compactMap(\.sleep), timeZone: zone, mapping: mapping) {
                let timeline = HybridSleepBuilder.merge(ring: analysis.intervals,
                    health: healthKit?.healthKitSleepTimeline ?? healthKit?.sleep?.segments ?? [],
                                                       device: first.ring.deviceID)
                payload.sourceSleep = healthKit?.sleep
                payload.sourceSleepSessions = healthKit?.sleepSessions
                payload.sleepTimeline = timeline
                if let lo = timeline.first?.start, let hi = timeline.last?.end {
                    payload.sleepReplacementWindow = HealthTimeWindow(start: lo, end: hi)
                }
                payload.sleep = HybridSleepBuilder.summary(timeline)
                let selected = HybridSleepBuilder.sessions(timeline).map { session -> SleepSession in
                    var value = session
                    value.sourceDeviceID = first.ring.deviceID
                    value.clockTimeZone = zone.identifier
                    let formatter = DateFormatter(); formatter.timeZone = zone
                    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                    value.day = formatter.string(from: value.end)
                    value.sessionID = "sleep-" + SmartRingSample.hash(Data("\(first.ring.deviceID)|\(zone.identifier)|\(value.start.timeIntervalSince1970)".utf8))
                    value.conflicting = timeline.contains { $0.start < value.end && $0.end > value.start && $0.conflicting }
                    return value
                }
                let unrepresented = (healthKit?.sleepSessions ?? []).filter { old in
                    !timeline.contains { $0.stage != "missing" && $0.start < old.end && $0.end > old.start }
                }
                payload.sleepSessions = (unrepresented + selected).sorted { $0.start < $1.start }
            }
        }
        return payload
    }
}
