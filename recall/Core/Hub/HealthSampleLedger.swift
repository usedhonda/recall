import Foundation

/// Decides what of a HealthKit change is news to Hub. A source that rewrites its data
/// deletes samples and saves the same values under new uuids; neither side of that is
/// sent. A deletion goes out only when Hub holds the sample and no same-content copy
/// remains in HealthKit. Pure value type: the caller saves it after the outbox accepts.
struct HealthSampleLedger: Codable, Equatable {
    private struct Entry: Codable, Equatable {
        var hubUUID: String
        var liveUUIDs: Set<String>
        var measuredAt: Date
    }

    private var entries: [String: Entry] = [:]
    private var keyByUUID: [String: String] = [:]

    static func contentKey(_ sample: RawHealthSample) -> String {
        [sample.type, "\(sample.start.timeIntervalSince1970)", "\(sample.end.timeIntervalSince1970)",
         sample.value.map { "\($0)" } ?? "", sample.unit ?? "", sample.valueText ?? "",
         sample.sourceBundleId ?? "", sample.durationSeconds.map { "\($0)" } ?? ""].joined(separator: "|")
    }

    /// Items first: a rewrite in one page must find its new copy before the old one goes.
    mutating func news(items: [RawHealthSample], deleted: [String]) -> (items: [RawHealthSample], deleted: [String]) {
        var sendItems: [RawHealthSample] = []
        var sendDeleted: [String] = []
        for sample in items {
            let key = Self.contentKey(sample)
            keyByUUID[sample.uuid] = key
            if entries[key] != nil {
                entries[key]?.liveUUIDs.insert(sample.uuid)
            } else {
                entries[key] = Entry(hubUUID: sample.uuid, liveUUIDs: [sample.uuid], measuredAt: sample.end)
                sendItems.append(sample)
            }
        }
        for uuid in deleted {
            guard let key = keyByUUID.removeValue(forKey: uuid) else { continue }
            entries[key]?.liveUUIDs.remove(uuid)
            if entries[key]?.liveUUIDs.isEmpty == true, let hubUUID = entries[key]?.hubUUID {
                sendDeleted.append(hubUUID)
                entries[key] = nil
            }
        }
        return (sendItems, sendDeleted)
    }

    /// Hub keeps raw health 30 days from receipt; later rewrites of older data are not worth tracking.
    mutating func prune(before cutoff: Date) {
        for (key, entry) in entries where entry.measuredAt < cutoff {
            entry.liveUUIDs.forEach { keyByUUID[$0] = nil }
            entries[key] = nil
        }
    }
}
