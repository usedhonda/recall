import Foundation
import Observation

struct HubRequestTiming: Codable, Sendable, Equatable {
    let phase: String
    let dnsMilliseconds: Int?
    let connectMilliseconds: Int?
    let tlsMilliseconds: Int?
    let reusedConnection: Bool
    let proxyConnection: Bool

    init(dnsStart: Date? = nil, dnsEnd: Date? = nil,
         connectStart: Date? = nil, connectEnd: Date? = nil,
         tlsStart: Date? = nil, tlsEnd: Date? = nil,
         requestStart: Date? = nil, requestEnd: Date? = nil,
         responseStart: Date? = nil, reusedConnection: Bool = false,
         proxyConnection: Bool = false) {
        if responseStart != nil { phase = "response_started" }
        else if requestEnd != nil { phase = "request_sent" }
        else if requestStart != nil { phase = "request_started" }
        else if tlsEnd != nil { phase = "tls_completed" }
        else if tlsStart != nil { phase = "tls_started" }
        else if connectEnd != nil { phase = "connected" }
        else if connectStart != nil { phase = "connecting" }
        else if dnsEnd != nil { phase = "dns_completed" }
        else if dnsStart != nil { phase = "dns_started" }
        else { phase = "not_reported" }
        func milliseconds(_ start: Date?, _ end: Date?) -> Int? {
            guard let start, let end else { return nil }
            let value = (end.timeIntervalSince(start) * 1_000).rounded()
            guard value.isFinite, value >= 0, value < Double(Int.max) else { return nil }
            return Int(value)
        }
        dnsMilliseconds = milliseconds(dnsStart, dnsEnd)
        connectMilliseconds = milliseconds(connectStart, connectEnd)
        tlsMilliseconds = milliseconds(tlsStart, tlsEnd)
        self.reusedConnection = reusedConnection
        self.proxyConnection = proxyConnection
    }
}

struct HubRequestDiagnostic: Codable, Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let endpointSHA256: String
    var completedAt: Date?
    var httpStatus: Int?
    var urlErrorCode: Int?
    var timing: HubRequestTiming?

    var summary: String {
        let result = httpStatus.map { "HTTP \($0)" }
            ?? urlErrorCode.map { "URL error \($0)" }
            ?? (completedAt == nil ? "In progress" : "No HTTP response")
        return "\(result); last reported phase: \(timing?.phase ?? "not_reported")"
    }
}

/// Bounded, body-free evidence from real requests only. No probe or retry loop.
@Observable
@MainActor
final class HubConnectionDiagnostics {
    static let shared = HubConnectionDiagnostics()
    private static let key = "hub.connection-diagnostics.v1"
    private let defaults: UserDefaults
    private var lastLoggedSignature: String?
    private(set) var requests: [HubRequestDiagnostic]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requests = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([HubRequestDiagnostic].self, from: $0) }
            .map { Array($0.prefix(20)) } ?? []
    }

    func started(id: UUID, endpointSHA256: String, at now: Date = Date()) {
        requests.insert(.init(id: id, startedAt: now, endpointSHA256: endpointSHA256), at: 0)
        requests = Array(requests.prefix(20))
        persist()
    }

    func collected(id: UUID, timing: HubRequestTiming) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].timing = timing
        persist()
        logIfChanged(requests[index])
    }

    func completed(id: UUID, status: Int? = nil, urlError: Int? = nil, at now: Date = Date()) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        requests[index].completedAt = now
        requests[index].httpStatus = status
        requests[index].urlErrorCode = urlError
        persist()
        logIfChanged(requests[index])
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(requests) { defaults.set(data, forKey: Self.key) }
    }

    private func logIfChanged(_ request: HubRequestDiagnostic) {
        guard request.completedAt != nil else { return }
        let signature = "\(request.endpointSHA256)|\(request.summary)"
        guard signature != lastLoggedSignature else { return }
        lastLoggedSignature = signature
        ActivityLogger.shared.log(.network, "Hub diagnostic endpoint_sha256=\(request.endpointSHA256) \(request.summary)")
    }
}
