import Foundation
import CoreLocation

/// Flat sample format matching server's expected { "samples": [...], "health": {...} } schema
struct TelemetrySampleBatch: Encodable {
    let samples: [TelemetrySample]
    var health: HealthSummary?
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
