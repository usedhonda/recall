import Foundation
import CoreLocation

/// Location sample for batch upload
struct LocationSample: Codable, Identifiable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let altitude: Double?
    let speed: Double?
    let timestamp: Date
    /// "good" / "approx" / nil. Mirrors `LocationPayload.quality` so the
    /// signal survives the queue path. Older samples persisted before this
    /// field existed decode as nil thanks to the optional declaration.
    var quality: String?
    /// See `TelemetrySample.fixId`. Optional so samples persisted before this field
    /// existed still decode.
    var fixId: String?

    /// Derived home-Wi-Fi state: "home" / "away" / nil. Mirrors
    /// `LocationPayload.wifi` so the signal survives the queue path. Optional so
    /// samples persisted before this field existed still decode as nil.
    var wifi: String?
    /// Network name and the age of that reading, mirroring `LocationPayload`.
    var wifiSSID: String?
    var wifiSSIDAgeSeconds: Int?
    var wifiConnected: Bool?

    // Phase 1 (Track 2 — phantom drift detection metadata, 2026-05-04).
    // All optional so samples persisted before this field existed still decode.
    var speedAccuracy: Double?
    var course: Double?
    var courseAccuracy: Double?
    var verticalAccuracy: Double?
    var floor: Int?
    var producedByAccessory: Bool?
    var simulatedBySoftware: Bool?

    init(latitude: Double, longitude: Double, accuracy: Double, altitude: Double?, speed: Double?, timestamp: Date, quality: String? = nil) {
        self.id = UUID()
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.altitude = altitude
        self.speed = speed
        self.timestamp = timestamp
        self.quality = quality
        self.wifi = ConnectivityMonitor.shared.wifiContext
        self.wifiSSID = ConnectivityMonitor.shared.currentSSID
        self.wifiSSIDAgeSeconds = ConnectivityMonitor.shared.ssidAgeSeconds
        self.wifiConnected = ConnectivityMonitor.shared.isOnNamedWiFi
    }

    init(from location: CLLocation, quality: String? = nil, fixId: String? = nil) {
        self.id = UUID()
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.accuracy = location.horizontalAccuracy
        self.altitude = location.altitude
        self.speed = location.speed >= 0 ? location.speed : nil
        self.timestamp = location.timestamp
        self.quality = quality
        self.fixId = fixId
        self.wifi = ConnectivityMonitor.shared.wifiContext
        self.wifiSSID = ConnectivityMonitor.shared.currentSSID
        self.wifiSSIDAgeSeconds = ConnectivityMonitor.shared.ssidAgeSeconds
        self.wifiConnected = ConnectivityMonitor.shared.isOnNamedWiFi

        self.speedAccuracy = location.speedAccuracy >= 0 ? location.speedAccuracy : nil
        self.course = location.course >= 0 ? location.course : nil
        self.courseAccuracy = location.courseAccuracy >= 0 ? location.courseAccuracy : nil
        self.verticalAccuracy = location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil
        self.floor = location.floor?.level
        if let info = location.sourceInformation {
            self.producedByAccessory = info.isProducedByAccessory
            self.simulatedBySoftware = info.isSimulatedBySoftware
        }
    }
}

/// Persistent queue for background location samples
/// Uses JSON file storage for simplicity and reliability
actor LocationQueue {
    private var samples: [LocationSample] = []
    private var legacyDeliveredIDs: Set<UUID> = []
    private var storageHealthy = true
    private var mutationInProgress = false
    private let fileURL: URL
    private let legacyDeliveredURL: URL

    static let shared = LocationQueue()

    private init() {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = documentsDir.appendingPathComponent("recall_location_queue.json")
        self.legacyDeliveredURL = documentsDir.appendingPathComponent("recall_location_legacy_delivered.json")
        let loaded = Self.loadSamplesFromDisk(fileURL: fileURL)
        self.samples = loaded.samples
        self.storageHealthy = loaded.healthy
        let sidecar = Self.loadLegacyDelivered(fileURL: legacyDeliveredURL)
        self.legacyDeliveredIDs = sidecar.ids
        self.storageHealthy = self.storageHealthy && sidecar.healthy
    }

    // MARK: - Queue Operations

    // Every mutator owns this gate across the external reservation await.
    // Contention refuses new admission; it never evicts an existing sample.
    @discardableResult
    func enqueue(_ sample: LocationSample) async -> Bool {
        guard storageHealthy, !mutationInProgress else { return false }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let previous = samples
        var proposed = samples; proposed.append(sample)
        do {
            try await reserve(samples: proposed, delivered: legacyDeliveredIDs)
            samples = proposed
            guard saveToDisk() else {
                samples = previous
                await reportFailure("queue_disk_failure")
                // Keep the larger reservation on failure; never undercount disk.
                return false
            }
            return true
        } catch {
            await reportFailure("queue_admission_failed")
            return false
        }
    }

    func peek(max: Int) -> [LocationSample] { Array(samples.prefix(min(max, samples.count))) }
    func hasPending() -> Bool { !samples.isEmpty }
    func count() -> Int { samples.count }
    func legacyDelivered(_ id: UUID) -> Bool { legacyDeliveredIDs.contains(id) }

    func reconcileHubReservation() async -> Bool {
        guard storageHealthy, !mutationInProgress else { return false }
        mutationInProgress = true
        defer { mutationInProgress = false }
        do {
            try await reserve(samples: samples, delivered: legacyDeliveredIDs)
            return true
        } catch {
            await reportFailure("queue_reservation_failed")
            return false
        }
    }

    @discardableResult
    func remove(ids: Set<UUID>) async -> Bool {
        guard storageHealthy, !mutationInProgress else { return false }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let previous = samples
        samples.removeAll { ids.contains($0.id) }
        guard saveToDisk() else {
            samples = previous
            await reportFailure("queue_disk_failure")
            return false
        }
        // Remove only after queue persistence. A crash leaves extra dedup IDs,
        // never a replay of an already-sent sample still present in the queue.
        let previousIDs = legacyDeliveredIDs
        legacyDeliveredIDs.subtract(ids)
        guard saveLegacyDelivered() else {
            legacyDeliveredIDs = previousIDs
            await reportFailure("queue_sidecar_failure")
            return false
        }
        do { try await reserve(samples: samples, delivered: legacyDeliveredIDs) }
        catch { await reportFailure("queue_reservation_release_failed") }
        return true
    }

    @discardableResult
    func markLegacyDelivered(_ ids: Set<UUID>) async -> Bool {
        guard storageHealthy, !mutationInProgress else { return false }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let previous = legacyDeliveredIDs
        let proposed = previous.union(ids)
        do { try await reserve(samples: samples, delivered: proposed) }
        catch { await reportFailure("queue_sidecar_capacity"); return false }
        legacyDeliveredIDs = proposed
        guard saveLegacyDelivered() else {
            legacyDeliveredIDs = previous
            await reportFailure("queue_sidecar_failure")
            return false
        }
        return true
    }

    private func reserve(samples proposed: [LocationSample], delivered: Set<UUID>) async throws {
        guard await MainActor.run(body: { HubDeliveryService.shared.isEnabled(.gpsDelivery) }) else { return }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = Int64((try encoder.encode(proposed)).count +
            (try encoder.encode(delivered.map(\.uuidString).sorted())).count)
        try await HubDeliveryService.shared.reserveQueueBytes(route: .gpsDelivery,
            key: "location-queue", bytes: bytes)
    }

    private func reportFailure(_ reason: String) async {
        await HubDeliveryService.shared.recordGap(route: .gpsDelivery, reason: reason)
    }

    // MARK: - Persistence

    private nonisolated static func loadSamplesFromDisk(fileURL: URL) -> (samples: [LocationSample], healthy: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([], true) }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let samples = try decoder.decode([LocationSample].self, from: data)
            print("[LocationQueue] Loaded \(samples.count) pending samples from disk")
            return (samples, true)
        } catch {
            print("[LocationQueue] Failed to load from disk: \(error)")
            return ([], false)
        }
    }

    @discardableResult
    private func saveToDisk() -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(samples)
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            print("[LocationQueue] Failed to save to disk: \(error)")
            storageHealthy = false
            return false
        }
    }

    private nonisolated static func loadLegacyDelivered(fileURL: URL) -> (ids: Set<UUID>, healthy: Bool) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ([], true) }
        guard let data = try? Data(contentsOf: fileURL),
              let values = try? JSONDecoder().decode([String].self, from: data),
              values.allSatisfy({ UUID(uuidString: $0) != nil }) else { return ([], false) }
        return (Set(values.compactMap(UUID.init(uuidString:))), true)
    }

    @discardableResult
    private func saveLegacyDelivered() -> Bool {
        let values = legacyDeliveredIDs.map(\.uuidString).sorted()
        guard let data = try? JSONEncoder().encode(values),
              (try? data.write(to: legacyDeliveredURL, options: .atomic)) != nil else {
            storageHealthy = false
            return false
        }
        return true
    }
}
