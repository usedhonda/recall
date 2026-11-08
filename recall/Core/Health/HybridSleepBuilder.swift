import Foundation
import SmartRingKit

struct HybridSleepInterval: Codable, Equatable {
    let start: Date
    let end: Date
    let stage: String
    let source: String
    let sourceDeviceID: String?
    let conflicting: Bool
}

enum HybridSleepBuilder {
    static func merge(ring: [RingSleepInterval], health: [SleepSegment], device: String) -> [HybridSleepInterval] {
        let health = health.filter { $0.end > $0.start && $0.stage != "inBed" }
        let bounds = Set(ring.flatMap { [$0.start, $0.end] } + health.flatMap { [$0.start, $0.end] }).sorted()
        guard bounds.count > 1 else { return [] }
        var result: [HybridSleepInterval] = []
        for index in 0..<(bounds.count - 1) {
            let lo = bounds[index], hi = bounds[index + 1]
            let direct = ring.first { $0.start <= lo && $0.end >= hi }
            let fallback = health.filter { $0.start <= lo && $0.end >= hi }.sorted {
                if $0.end != $1.end { return $0.end > $1.end }
                return ($0.sourceBundleId ?? $0.source ?? "") < ($1.sourceBundleId ?? $1.source ?? "")
            }.first
            let stage: String, source: String, deviceID: String?, conflict: Bool
            if let direct, direct.stage != .missing {
                stage = direct.stage.rawValue; source = "SmartRingKit"; deviceID = device; conflict = direct.conflicting
            } else if let fallback {
                stage = fallback.stage; source = fallback.sourceBundleId ?? fallback.source ?? "HealthKit"
                deviceID = nil; conflict = false
            } else {
                stage = "missing"; source = "none"; deviceID = nil; conflict = false
            }
            if let last = result.last, last.end == lo, last.stage == stage,
               last.source == source, last.sourceDeviceID == deviceID, last.conflicting == conflict {
                result[result.count - 1] = HybridSleepInterval(start: last.start, end: hi, stage: stage,
                    source: source, sourceDeviceID: deviceID, conflicting: conflict)
            } else {
                result.append(HybridSleepInterval(start: lo, end: hi, stage: stage,
                    source: source, sourceDeviceID: deviceID, conflicting: conflict))
            }
        }
        return result
    }

    static func sessions(_ timeline: [HybridSleepInterval]) -> [SleepSession] {
        var groups: [[HybridSleepInterval]] = []
        for segment in timeline where segment.stage != "missing" {
            if let last = groups.last?.last, segment.start.timeIntervalSince(last.end) < SleepSessionBuilder.sessionGap {
                groups[groups.count - 1].append(segment)
            } else { groups.append([segment]) }
        }
        return groups.map { group in
            func minutes(_ stages: Set<String>) -> Double {
                group.filter { stages.contains($0.stage) }.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
            }
            return SleepSession(lightMinutes: minutes(["light"]), unknownMinutes: minutes(["unknown"]),
                missingMinutes: group.last!.end.timeIntervalSince(group[0].start) / 60 - minutes(Set(group.map(\.stage))),
                start: group[0].start, end: group.last!.end,
                totalMinutes: minutes(["light", "deep", "rem", "asleepREM", "asleepDeep", "asleepCore", "asleepUnspecified"]),
                remMinutes: minutes(["rem", "asleepREM"]), deepMinutes: minutes(["deep", "asleepDeep"]),
                coreMinutes: minutes(["asleepCore"]), awakeMinutes: minutes(["awake"]),
                source: "Recall hybrid", sourceBundleId: "recall.hybrid.sleep", sampleCount: group.count)
        }
    }

    static func summary(_ timeline: [HybridSleepInterval]) -> SleepSummary? {
        guard let last = sessions(timeline).last else { return nil }
        return SleepSummary(light: last.lightMinutes, unknown: last.unknownMinutes, missing: last.missingMinutes,
            total: last.totalMinutes, rem: last.remMinutes, deep: last.deepMinutes, core: last.coreMinutes,
            awake: last.awakeMinutes, segments: timeline.filter { $0.start >= last.start && $0.end <= last.end }.map {
                SleepSegment(start: $0.start, end: $0.end, stage: $0.stage, source: $0.source,
                             sourceBundleId: $0.source, deviceModel: $0.sourceDeviceID == nil ? nil : "FFF0 ring")
            })
    }
}
