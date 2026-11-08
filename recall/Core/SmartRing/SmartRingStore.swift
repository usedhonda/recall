import Foundation

/// Separate, protected local archive. Nothing advances to queued until durable Hub
/// admission succeeds. A crash between admission and save retries the same envelope.
actor SmartRingStore {
    struct Entry: Codable {
        let sample: SmartRingSample
        let capturedAt: Date
        var queued: Bool
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

    @discardableResult
    func merge(_ samples: [SmartRingSample], capturedAt: Date) throws -> Int {
        var known = Set(entries.map { $0.sample.uuid })
        let fresh = samples.filter { known.insert($0.uuid).inserted }
        guard !fresh.isEmpty else { return 0 }
        var next = entries
        // Keep admitted identities too: a full ring download must not re-send old data.
        guard next.count + fresh.count <= capacity else { throw Failure.archiveFull }
        next += fresh.map { Entry(sample: $0, capturedAt: capturedAt, queued: false) }
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
