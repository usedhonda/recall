import Foundation
import CoreLocation

/// Flat sample format matching server's expected { "samples": [...], "health": {...} } schema.
/// `health2` carries the new self-describing payload (records with measuredAt +
/// source). Server may consume `health` (legacy) and `health2` (new) in parallel
/// during migration; once `health2` is fully supported `health` will be dropped.
struct TelemetrySampleBatch: Encodable {
    let samples: [TelemetrySample]
    var health: HealthSummary?
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
