import Foundation

/// Admission guards never delete pending originals. Source files and the real
/// encoded outbox copy both consume the original lane's budget.
@MainActor
final class OriginalCapacity {
    static let shared = OriginalCapacity()
    private var audioReservations: Set<UUID> = []
    private var glassesReservations: [UUID: Int64] = [:]

    private init() {}

    func reserveAudioChunk() async -> UUID? {
        guard await canStartAudioChunk() else { return nil }
        let token = UUID()
        audioReservations.insert(token)
        return token
    }

    func releaseAudioChunk(_ token: UUID) {
        audioReservations.remove(token)
    }

    func canStartAudioChunk() async -> Bool {
        let hub = HubDeliveryService.shared
        guard hub.isEnabled(.audioOriginal) else { return true }
        do {
            let cap = Int64(AppSettings.shared.storageCapMB) * 1024 * 1024
            let queue = try await hub.retainedBytes(route: .audioOriginal)
            let files = try HubDeliveryService.originalDirectoryBytes(for: .audioOriginal)
            // A start guard is not a proof of a maximum encoded chunk size.
            // Audio activation also requires the capture reservation acceptance.
            guard audioReservations.isEmpty, files + queue < cap else {
                await hub.recordGap(route: .audioOriginal, reason: "capacity_exhausted")
                return false
            }
            return true
        } catch {
            await hub.recordGap(route: .audioOriginal, reason: "capacity_read_failed")
            return false
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
        do {
            let queue = try await hub.retainedBytes(route: .glassesOriginal)
            let files = try HubDeliveryService.originalDirectoryBytes(for: .glassesOriginal)
            // Reserve real imported bytes plus their encoded outbox copy and
            // fixed metadata/receipt headroom before the synchronous file copy.
            let cap: Int64 = 512 * 1024 * 1024
            guard bytes >= 0, bytes <= cap else { return nil }
            let needed = bytes + 4 * ((bytes + 2) / 3) + 65_536
            let reserved = glassesReservations.values.reduce(Int64(0), +)
            guard needed <= cap, files + queue + reserved <= cap - needed else {
                await hub.recordGap(route: .glassesOriginal, reason: "capacity_exhausted")
                return nil
            }
            let token = UUID()
            glassesReservations[token] = needed
            return token
        } catch {
            await hub.recordGap(route: .glassesOriginal, reason: "capacity_read_failed")
            return nil
        }
    }

    func releaseGlasses(_ token: UUID) {
        glassesReservations.removeValue(forKey: token)
    }
}
