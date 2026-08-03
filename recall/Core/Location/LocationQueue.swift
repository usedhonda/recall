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

    /// Derived home-Wi-Fi state: "home" / "away" / nil. Mirrors
    /// `LocationPayload.wifi` so the signal survives the queue path. Optional so
    /// samples persisted before this field existed still decode as nil.
    var wifi: String?

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
    }

    init(from location: CLLocation, quality: String? = nil) {
        self.id = UUID()
        self.latitude = location.coordinate.latitude
        self.longitude = location.coordinate.longitude
        self.accuracy = location.horizontalAccuracy
        self.altitude = location.altitude
        self.speed = location.speed >= 0 ? location.speed : nil
        self.timestamp = location.timestamp
        self.quality = quality
        self.wifi = ConnectivityMonitor.shared.wifiContext

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
    private let fileURL: URL

    static let shared = LocationQueue()

    private init() {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = documentsDir.appendingPathComponent("recall_location_queue.json")
        self.samples = Self.loadSamplesFromDisk(fileURL: fileURL)
    }

    // MARK: - Queue Operations

    func enqueue(_ sample: LocationSample) {
        samples.append(sample)
        saveToDisk()
    }

    func drain(max: Int) -> [LocationSample] {
        let count = min(max, samples.count)
        let drained = Array(samples.prefix(count))
        samples.removeFirst(count)
        saveToDisk()
        return drained
    }

    func hasPending() -> Bool {
        !samples.isEmpty
    }

    func count() -> Int {
        samples.count
    }

    func remove(ids: Set<UUID>) {
        samples.removeAll { ids.contains($0.id) }
        saveToDisk()
    }

    func clear() {
        samples.removeAll()
        saveToDisk()
    }

    // MARK: - Persistence

    private nonisolated static func loadSamplesFromDisk(fileURL: URL) -> [LocationSample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let samples = try decoder.decode([LocationSample].self, from: data)
            print("[LocationQueue] Loaded \(samples.count) pending samples from disk")
            return samples
        } catch {
            print("[LocationQueue] Failed to load from disk: \(error)")
            return []
        }
    }

    private func saveToDisk() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(samples)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[LocationQueue] Failed to save to disk: \(error)")
        }
    }
}
