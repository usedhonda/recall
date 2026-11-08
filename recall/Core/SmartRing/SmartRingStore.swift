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
    }

    init(url: URL, capacity: Int = 10_000, uploadFloor: Date = Date().addingTimeInterval(-14 * 86400)) throws {
        self.url = url
        self.capacity = capacity
        if FileManager.default.fileExists(atPath: url.path) {
            let saved = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            entries = saved.entries
            frozenBatch = saved.frozenBatch
            self.uploadFloor = saved.uploadFloor
        } else {
            entries = []
            frozenBatch = []
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
        let samples = entries.map(\.sample).filter {
            $0.type == type && $0.ring.deviceID == deviceID && $0.ring.firmware == firmware &&
            $0.ring.clockTimeZone == timeZone
        }.sorted { $0.start > $1.start }
        // Retain one overlapping anchor; this is not an arbitrary cutoff or a receipt cursor.
        return samples.dropFirst().first?.ring.deviceTime
    }

    @discardableResult
    func merge(_ samples: [SmartRingSample], capturedAt: Date, reservedSlots: Int = 0,
               availableAt: Date? = nil) throws -> Int {
        var known = Set(entries.map { $0.sample.uuid })
        let fresh = samples.filter { known.insert($0.uuid).inserted }
        var next = entries
        if let availableAt {
            let receivedIDs = Set(samples.map(\.uuid))
            for index in next.indices where next[index].availableAt == nil && receivedIDs.contains(next[index].sample.uuid) {
                next[index].availableAt = availableAt
            }
        }
        // Keep admitted identities too: a full ring download must not re-send old data.
        guard fresh.isEmpty || next.count + fresh.count + reservedSlots <= capacity else { throw Failure.archiveFull }
        next += fresh.map {
            var sample = $0; sample.availableAt = availableAt
            return Entry(sample: sample, capturedAt: capturedAt, queued: false, availableAt: availableAt)
        }
        if fresh.isEmpty && availableAt == nil { return 0 }
        try save(next, batch: frozenBatch)
        entries = next
        return fresh.count
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

    private func save(_ entries: [Entry], batch: [String]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Archive(entries: entries, frozenBatch: batch, uploadFloor: uploadFloor))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var file = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }
}
