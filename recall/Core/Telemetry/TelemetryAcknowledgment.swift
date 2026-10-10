import Foundation

/// Validation of the receiver's HTTP acknowledgement. A successful HTTP
/// status alone is not enough for a health send: the receiver must explicitly
/// report that Health was accepted.
enum TelemetryAcknowledgment {
    enum Error: Swift.Error, LocalizedError, Equatable {
        case unacceptableStatus(Int)
        case malformedResponse
        case healthNotReceived

        var errorDescription: String? {
            switch self {
            case .unacceptableStatus(let status): return "HTTP status \(status) is not successful"
            case .malformedResponse: return "malformed telemetry acknowledgement"
            case .healthNotReceived: return "receiver did not acknowledge Health"
            }
        }
    }

    static func validate(data: Data, statusCode: Int, requiresHealth: Bool) throws -> TelemetryResponse {
        guard (200...299).contains(statusCode) else {
            throw Error.unacceptableStatus(statusCode)
        }
        let response: TelemetryResponse
        do {
            response = try JSONDecoder().decode(TelemetryResponse.self, from: data)
        } catch {
            throw Error.malformedResponse
        }
        if requiresHealth && response.healthReceived != true {
            throw Error.healthNotReceived
        }
        return response
    }
}
