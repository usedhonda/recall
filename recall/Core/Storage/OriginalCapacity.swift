import Foundation

/// Admission guards never delete pending originals. Source files and the real
/// encoded outbox copy both consume the original lane's budget.
@MainActor
final class OriginalCapacity {
    static let shared = OriginalCapacity()
    // Enforced by the bounded CAF write/resize callbacks, not estimated bitrate.
    static let maximumAudioOriginalBytes: Int64 = 14 * 1024 * 1024
    static let maximumAudioCaptureReservation = maximumAudioOriginalBytes
        + Int64(HubProducerContract.maximumEncodedJSONBytes) + 4096
    private var audioReservations: Set<UUID> = []

    private init() {}

    func reserveAudioChunk() async -> UUID? {
        let token = UUID()
        guard audioReservations.isEmpty else { return nil }
        // Claim before suspension so two writers cannot pass the initial guard.
        audioReservations.insert(token)
        guard HubDeliveryService.shared.isEnabled(.audioOriginal) else { return token }
        do {
            try await HubDeliveryService.shared.reserveAudioCapture(token: token,
                bytes: Self.maximumAudioCaptureReservation)
            return token
        } catch {
            audioReservations.remove(token)
            await HubDeliveryService.shared.recordGap(route: .audioOriginal, reason: "capture_capacity_rejected")
            return nil
        }
    }

    func releaseAudioChunk(_ token: UUID) {
        guard audioReservations.remove(token) != nil else { return }
        if HubDeliveryService.shared.isEnabled(.audioOriginal) {
            Task { await HubDeliveryService.shared.releaseAudioCapture(token: token) }
        }
    }

    func canImportGlasses(bytes: Int64) async -> Bool {
        guard let token = await reserveGlasses(bytes) else { return false }
        releaseGlasses(token)
        return true
    }

    func reserveGlasses(_ bytes: Int64) async -> UUID? {
        let hub = HubDeliveryService.shared
        guard hub.isEnabled(.glassesOriginal) else { return UUID() }
        guard let token = hub.beginOriginalMutation(.glassesOriginal) else { return nil }
        var admitted = false
        defer { if !admitted { hub.finishOriginalMutation(.glassesOriginal, token: token) } }
        do {
            let queue = try await hub.retainedBytes(route: .glassesOriginal)
            let files = try HubDeliveryService.originalDirectoryBytes(for: .glassesOriginal)
            // Reserve real imported bytes plus their encoded outbox copy and
            // fixed metadata/receipt headroom before the synchronous file copy.
            let cap: Int64 = 512 * 1024 * 1024
            guard bytes >= 0, bytes <= cap else { return nil }
            let needed = bytes + 4 * ((bytes + 2) / 3) + 65_536
            guard needed <= cap, files + queue <= cap - needed else {
                await hub.recordGap(route: .glassesOriginal, reason: "capacity_exhausted")
                return nil
            }
            admitted = true
            return token
        } catch {
            await hub.recordGap(route: .glassesOriginal, reason: "capacity_read_failed")
            return nil
        }
    }

    func releaseGlasses(_ token: UUID) {
        HubDeliveryService.shared.finishOriginalMutation(.glassesOriginal, token: token)
    }
}
