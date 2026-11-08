import Foundation
import SmartRingKit

struct SmartRingFatigueEstimate: Codable {
    let sourceDeviceID: String
    let firmware: String
    let clockTimeZone: String
    let estimate: RingFatigueEstimate
}

/// Research outputs stay separate from measured health records and vendor-app stress.
enum SmartRingResearch {
    struct Result {
        let inputs: RingStressFeatureSet
        let estimate: RingFatigueEstimate?
    }

    static func evaluate(_ received: [SmartRingSample], deviceID: String, firmware: String,
                         timeZone: TimeZone, method: RingFatigueCorrection?, at now: Date) throws -> Result {
        let samples = received.filter {
            $0.ring.deviceID == deviceID && $0.ring.firmware == firmware &&
            $0.ring.clockTimeZone == timeZone.identifier &&
            $0.start <= now &&
            $0.availableAt.map { $0 <= now } == true
        }
        let histories = samples.compactMap { sample -> RingDecodedHistory? in
            guard let command = sample.ring.rawBytes.first else { return nil }
            return RingHistoryCodec.decode(RingRawHistory(command: command, notifications: [sample.ring.rawBytes]))
        }
        // Engineering freshness policy, not a physiological threshold. No guessed sleep window.
        let inputs = try RingStressInputs.assemble(histories, at: now, timeZone: timeZone,
            maximumAge: 600, referenceWindow: DateInterval(start: now.addingTimeInterval(-7 * 86400), end: now))
        guard let method else { return Result(inputs: inputs, estimate: nil) }
        let anchors = samples.compactMap { sample -> RingNativeFatigueAnchor? in
            guard sample.type == "smart_ring.hrv_history", let value = sample.ring.stressRaw,
                  let available = sample.availableAt else { return nil }
            return RingNativeFatigueAnchor(measuredAt: sample.start, availableAt: available, value: value)
        }
        // Only independently measured 0x55 BPM enters the model: no 0x56 HRV/HR/fatigue leakage.
        let training = samples.compactMap { sample -> RingFatigueSample? in
            guard sample.type == "smart_ring.sensor.85", let available = sample.availableAt,
                  let heart = sample.sensor?.measurements.first(where: { $0.name == "heartRate" && $0.unit == "bpm" }),
                  heart.value > 0 else { return nil }
            return RingFatigueSample(measuredAt: sample.start, availableAt: available, values: ["heartRateBPM": heart.value])
        }
        let policy = RingFatigueConfiguration(correction: method, featureNames: ["heartRateBPM"])
        let model = try RingFatigueEstimator(samples: training, anchors: anchors,
            before: now, asOf: now, configuration: policy)
        let estimate = try model.estimate(samples: training, anchors: anchors, at: now, asOf: now)
        return Result(inputs: inputs, estimate: estimate)
    }
}
