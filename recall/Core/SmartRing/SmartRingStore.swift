import Foundation
import SmartRingKit

/// Separate, protected local archive. Nothing advances to queued until durable Hub
/// admission succeeds. A crash between admission and save retries the same envelope.
actor SmartRingStore {
    struct Entry: Codable {
        let sample: SmartRingSample
        let capturedAt: Date
        var queued: Bool
        var availableAt: Date? = nil
    }
    struct Counts { let stored: Int; let pending: Int; let held: Int }
    enum Failure: Error, LocalizedError {
        case archiveFull
        var errorDescription: String? { "Ring archive is full. Existing records were preserved." }
    }

    private let url: URL
    private var entries: [Entry]
    private let capacity: Int
    private var frozenBatch: [String]
    private let uploadFloor: Date

    private struct Archive: Codable {
        var entries: [Entry]
        var frozenBatch: [String]
        let uploadFloor: Date
        /// Compact identities of readings pruned after durable outbox admission.
        var pruned: [Identity]? = nil
    }

    /// Duplicate protection for a reading whose full entry was pruned.
    struct Identity: Codable {
        let uuid: String
        let readingKey: String
        let end: Date
    }

    /// Ring history is not re-sent beyond this age; older identities are not needed.
    private static let identityHorizon: TimeInterval = 14 * 86400
    private var pruned: [Identity]

    init(url: URL, capacity: Int = 10_000, uploadFloor: Date = Date().addingTimeInterval(-14 * 86400)) throws {
        self.url = url
        self.capacity = capacity
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            entries = saved.entries
            frozenBatch = saved.frozenBatch
            pruned = saved.pruned ?? []
            self.uploadFloor = saved.uploadFloor
        } else {
            entries = []
            frozenBatch = []
            pruned = []
            self.uploadFloor = uploadFloor
        }
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("smart-ring-history.json")
    }

    func counts() -> Counts {
        Counts(stored: entries.count, pending: entries.filter { !$0.queued }.count,
               held: entries.filter { !$0.queued && $0.sample.end < uploadFloor }.count)
    }

    func samplesForHealthSnapshot() -> [SmartRingSample] {
        entries.filter { $0.sample.end >= uploadFloor }.map {
            var sample = $0.sample
            sample.capturedAt = $0.capturedAt
            sample.availableAt = $0.availableAt
            return sample
        }
    }

    func inRetentionWindow(_ samples: [SmartRingSample]) -> [SmartRingSample] {
        samples.filter { $0.end >= uploadFloor }
    }

    func resumeHint(command: UInt8, deviceID: String, firmware: String, timeZone: String) -> RingTimestamp? {
        guard [0x55, 0x56, 0x62].contains(command) else { return nil }
        let type = command == 0x56 ? "smart_ring.hrv_history" : "smart_ring.sensor.\(command)"
        // The ring clock has no zone: resume by its own wall time, whatever zone the
        // stored samples were interpreted in, so a zone change does not re-read history.
        let utc = TimeZone(identifier: "UTC")!
        let samples = entries.map(\.sample).filter {
            $0.type == type && $0.ring.deviceID == deviceID && $0.ring.firmware == firmware
        }.sorted { ($0.ring.deviceTime.date(in: utc) ?? $0.start) > ($1.ring.deviceTime.date(in: utc) ?? $1.start) }
        // Retain one overlapping anchor; this is not an arbitrary cutoff or a receipt cursor.
        return samples.dropFirst().first?.ring.deviceTime
    }

    @discardableResult
    func merge(_ samples: [SmartRingSample], capturedAt: Date, reservedSlots: Int = 0,
               availableAt: Date? = nil) throws -> Int {
        var known = Set(entries.map { $0.sample.uuid } + pruned.map(\.uuid))
        // A reading already stored under another clock zone is the same measurement:
        // do not store or send it again with a new uuid.
        var readings = Set(entries.map { $0.sample.readingKey } + pruned.map(\.readingKey))
        let fresh = samples.filter { known.insert($0.uuid).inserted && readings.insert($0.readingKey).inserted }
        var next = entries
        if let availableAt {
            let receivedIDs = Set(samples.map(\.uuid))
            for index in next.indices where next[index].availableAt == nil && receivedIDs.contains(next[index].sample.uuid) {
                next[index].availableAt = availableAt
            }
        }
        // Keep admitted identities too: a full ring download must not re-send old data.
        var identities = pruned
        if !fresh.isEmpty, next.count + fresh.count + reservedSlots > capacity {
            prune(&next, &identities, free: next.count + fresh.count + reservedSlots - capacity)
        }
        guard fresh.isEmpty || next.count + fresh.count + reservedSlots <= capacity else { throw Failure.archiveFull }
        next += fresh.map {
            var sample = $0; sample.availableAt = availableAt
            return Entry(sample: sample, capturedAt: capturedAt, queued: false, availableAt: availableAt)
        }
        if fresh.isEmpty && availableAt == nil { return 0 }
        try save(next, batch: frozenBatch, pruned: identities)
        entries = next
        pruned = identities
        return fresh.count
    }

    /// Frees room by dropping the oldest entries whose batch is durably admitted to the Hub
    /// outbox (`queued`; the outbox retains it until the Hub receipt). Unqueued and frozen
    /// entries are never dropped. Each dropped reading leaves a compact identity so a full
    /// ring re-download adds nothing; identities past the ring's history horizon expire.
    /// The two newest entries per stream stay so `resumeHint` keeps its overlapping anchor.
    private func prune(_ entries: inout [Entry], _ identities: inout [Identity], free: Int) {
        let horizon = Date().addingTimeInterval(-Self.identityHorizon)
        identities.removeAll { $0.end < horizon }
        let frozen = Set(frozenBatch)
        var seen: [String: Int] = [:]
        var anchored = Set<String>()
        for entry in entries.sorted(by: { $0.sample.end > $1.sample.end }) {
            let key = entry.sample.type + "|" + entry.sample.ring.deviceID + "|" + entry.sample.ring.firmware
            seen[key, default: 0] += 1
            if seen[key]! <= 2 { anchored.insert(entry.sample.uuid) }
        }
        let doomed = entries.filter {
            $0.queued && !frozen.contains($0.sample.uuid) && !anchored.contains($0.sample.uuid)
        }.sorted { $0.sample.end < $1.sample.end }.prefix(free)
        let gone = Set(doomed.map { $0.sample.uuid })
        identities += doomed.map { Identity(uuid: $0.sample.uuid, readingKey: $0.sample.readingKey, end: $0.sample.end) }
        entries.removeAll { gone.contains($0.sample.uuid) }
    }

    /// The closure must return only after durable outbox admission, not on a disabled route.
    /// Caller serializes drain operations; a failed batch remains pending for the next pass.
    func drain(admit: (Data, String, Date) async throws -> Void) async throws {
        while true {
            try Task.checkCancellation()
            if frozenBatch.isEmpty {
                let ids = Array(entries.filter { !$0.queued && $0.sample.end >= uploadFloor }.prefix(200)).map { $0.sample.uuid }
                guard !ids.isEmpty else { return }
                // Freeze membership before the first admission. A later read must not
                // grow the final partial batch and change its retry identity/body.
                try save(entries, batch: ids)
                frozenBatch = ids
            }
            let members = Set(frozenBatch)
            let batch = entries.filter { members.contains($0.sample.uuid) }
            guard !batch.isEmpty else { return }
            let items = try batch.map { try HubRawEvent.encoder.encode($0.sample) }
            let payload = HubRawEvent.sourcePayload(items: items, deleted: [])
            let identity = "ring-" + SmartRingSample.hash(payload)
            let occurredAt = batch[0].capturedAt
            try await admit(payload, identity, occurredAt)
            // New records may have arrived during admission. Only mark this exact batch.
            let ids = Set(batch.map { $0.sample.uuid })
            var next = entries
            for i in next.indices where ids.contains(next[i].sample.uuid) { next[i].queued = true }
            try save(next, batch: [])
            entries = next
            frozenBatch = []
        }
    }

    private func save(_ entries: [Entry], batch: [String], pruned: [Identity]? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Archive(entries: entries, frozenBatch: batch, uploadFloor: uploadFloor, pruned: pruned ?? self.pruned))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
}
