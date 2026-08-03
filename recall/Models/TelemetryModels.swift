import Foundation
import CoreLocation

/// Flat sample format matching server's expected { "samples": [...], "health2": {...} } schema.
/// `health2` carries the self-describing payload (records with measuredAt +
/// source per metric). Server interprets each record by `metricId` + `unit` +
/// `aggregation` rather than relying on field names.
struct TelemetrySampleBatch: Encodable {
    let samples: [TelemetrySample]
    var health2: HealthPayload?
    var nowPlaying: NowPlayingSnapshot?
}

/// Single location sample for telemetry upload
struct TelemetrySample: Encodable {
    let id: String
    let lat: Double
    let lon: Double
    let accuracy: Double
    let altitude: Double?
    let speed: Double?
    let timestamp: Date
    /// "good" / "approx" / nil. Forwarded from `LocationSample.quality`
    /// (which mirrors `LocationManager.qualityFor`) so server can reason
    /// about reduced-accuracy fixes.
    let quality: String?

    /// Derived home-Wi-Fi state: "home" / "away" / nil. Derived on device from
    /// the user-set home SSID (ConnectivityMonitor.wifiContext); the raw SSID
    /// never leaves the device.
    let wifi: String?

    // Phase 1 (Track 2 — phantom drift detection metadata, 2026-05-04)
    let speedAccuracy: Double?
    let course: Double?
    let courseAccuracy: Double?
    let verticalAccuracy: Double?
    let floor: Int?
    let producedByAccessory: Bool?
    let simulatedBySoftware: Bool?

    init(
        id: String,
        lat: Double,
        lon: Double,
        accuracy: Double,
        altitude: Double?,
        speed: Double?,
        timestamp: Date,
        quality: String?,
        wifi: String? = nil,
        speedAccuracy: Double? = nil,
        course: Double? = nil,
        courseAccuracy: Double? = nil,
        verticalAccuracy: Double? = nil,
        floor: Int? = nil,
        producedByAccessory: Bool? = nil,
        simulatedBySoftware: Bool? = nil
    ) {
        self.id = id
        self.lat = lat
        self.lon = lon
        self.accuracy = accuracy
        self.altitude = altitude
        self.speed = speed
        self.timestamp = timestamp
        self.quality = quality
        self.wifi = wifi
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.floor = floor
        self.producedByAccessory = producedByAccessory
        self.simulatedBySoftware = simulatedBySoftware
    }

    init(from sample: LocationSample) {
        self.init(
            id: sample.id.uuidString,
            lat: sample.latitude,
            lon: sample.longitude,
            accuracy: sample.accuracy,
            altitude: sample.altitude,
            speed: sample.speed,
            timestamp: sample.timestamp,
            quality: sample.quality,
            wifi: sample.wifi,
            speedAccuracy: sample.speedAccuracy,
            course: sample.course,
            courseAccuracy: sample.courseAccuracy,
            verticalAccuracy: sample.verticalAccuracy,
            floor: sample.floor,
            producedByAccessory: sample.producedByAccessory,
            simulatedBySoftware: sample.simulatedBySoftware
        )
    }

    init(from payload: LocationPayload, id: String = UUID().uuidString) {
        self.init(
            id: id,
            lat: payload.latitude,
            lon: payload.longitude,
            accuracy: payload.accuracy,
            altitude: payload.altitude,
            speed: payload.speed,
            timestamp: payload.timestamp,
            quality: payload.quality,
            wifi: payload.wifi,
            speedAccuracy: payload.speedAccuracy,
            course: payload.course,
            courseAccuracy: payload.courseAccuracy,
            verticalAccuracy: payload.verticalAccuracy,
            floor: payload.floor,
            producedByAccessory: payload.producedByAccessory,
            simulatedBySoftware: payload.simulatedBySoftware
        )
    }
}

/// Server response for telemetry uploads
struct TelemetryResponse: Decodable {
    let received: Int
    let nextMinIntervalSec: Int?
}

/// Location data payload for foreground HTTP sends
struct LocationPayload: Codable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
    let altitude: Double?
    let speed: Double?
    let timestamp: Date
    let quality: String

    /// Derived home-Wi-Fi state: "home" / "away" / nil. Derived on device from
    /// the user-set home SSID; the raw SSID never leaves the device.
    let wifi: String?

    // Phase 1 (Track 2 — phantom drift detection metadata, 2026-05-04)
    let speedAccuracy: Double?
    let course: Double?
    let courseAccuracy: Double?
    let verticalAccuracy: Double?
    let floor: Int?
    let producedByAccessory: Bool?
    let simulatedBySoftware: Bool?

    init(from location: CLLocation, quality: String) {
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
        } else {
            self.producedByAccessory = nil
            self.simulatedBySoftware = nil
        }
    }
}

/// Result of the last location send attempt
enum LocationSendResult {
    case none
    case sent(status: Int, received: Int?, healthReceived: Bool?, body: String?)
    case filtered(String)
    case httpError(String)
}

/// Network error for location history tracking
struct NetworkError: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}

/// Network error for health history tracking
struct HealthNetworkError: Identifiable {
    let id = UUID()
    let timestamp: Date
    let message: String
}
