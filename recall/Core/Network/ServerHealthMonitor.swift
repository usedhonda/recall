import Foundation
import Observation
import OSLog
import UIKit

@Observable
@MainActor
final class ServerHealthMonitor {
    static let shared = ServerHealthMonitor()

    private(set) var isServerReachable: Bool = true
    private(set) var lastProbeAt: Date?
    private(set) var lastSuccessAt: Date?
    private(set) var consecutiveProbeFailures: Int = 0
    private(set) var lastError: String?
    private(set) var latencyMs: Int?
    private(set) var lastUploadSuccessAt: Date?

    private static let logger = Logger(subsystem: "com.recall", category: "ServerHealthMonitor")
    private static let foregroundInterval: TimeInterval = 60
    private static let backgroundInterval: TimeInterval = 300
    /// Interface flaps come in bursts (90-100/h overnight); probe at most once per window.
    private static let networkChangeProbeMinGap: TimeInterval = 30
    private static let failureThreshold = 3
    private static let probeTimeout: TimeInterval = 10
    /// Background probes ride the location heartbeat (same radio wake); a probe this
    /// close to a full interval counts as the cycle's probe.
    private static let backgroundAlignTolerance: TimeInterval = 30

    private let activity = ActivityLogger.shared

    private var probeTask: Task<Void, Never>?

    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = probeTimeout
        config.timeoutIntervalForResource = probeTimeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    enum ProbeReason: String {
        case scheduled
        case networkChange = "network-change"
        case manual
    }

    private init() {}

    func start() {
        guard probeTask == nil else { return }
        Self.logger.info("ServerHealthMonitor started")
        activity.log(.network, "Server health monitor started")
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // Background: the location heartbeat normally probes for us (see
                // heartbeatSent); this loop only covers the location-off case.
                if !self.backgroundProbeRecentlyRan() {
                    await self.probe(reason: .scheduled)
                }
                let interval = self.currentInterval
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stop() {
        probeTask?.cancel()
        probeTask = nil
    }

    private var currentInterval: TimeInterval {
        let state = UIApplication.shared.applicationState
        return state == .active ? Self.foregroundInterval : Self.backgroundInterval
    }

    /// Called by the location heartbeat after it sends, so the background probe shares
    /// that radio wake instead of waking it again at its own time.
    func heartbeatSent() {
        guard UIApplication.shared.applicationState != .active else { return }
        guard !backgroundProbeRecentlyRan() else { return }
        Task { await probe(reason: .scheduled) }
    }

    private func backgroundProbeRecentlyRan() -> Bool {
        guard UIApplication.shared.applicationState != .active, let last = lastProbeAt else { return false }
        return Date().timeIntervalSince(last) < Self.backgroundInterval - Self.backgroundAlignTolerance
    }

    func probeNow(reason: ProbeReason) {
        if reason == .networkChange, let last = lastProbeAt,
           Date().timeIntervalSince(last) < Self.networkChangeProbeMinGap {
            return
        }
        Task { await probe(reason: reason) }
    }

    func recordUploadSuccess() {
        lastUploadSuccessAt = Date()
        if !isServerReachable {
            isServerReachable = true
            consecutiveProbeFailures = 0
            Self.logger.info("Server reachable (upload success)")
            activity.log(.network, "Server reachable (upload success)")
        }
    }

    func recordUploadFailure(_ error: String) {
        // Upload failures inform L3 but don't directly flip isServerReachable;
        // that's the probe's job (L2).
        Self.logger.warning("Upload failure recorded: \(error)")
    }

    private func probe(reason: ProbeReason) async {
        let serverURL = AppSettings.shared.uploadServerURL
        guard !serverURL.isEmpty else { return }

        guard let url = URL(string: serverURL)?
            .appendingPathComponent("ingest") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        let start = CFAbsoluteTimeGetCurrent()
        lastProbeAt = Date()

        do {
            let (_, response) = try await probeSession.data(for: request)

            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            latencyMs = elapsed

            // Any HTTP response means the server is alive.
            // 200, 405 (Method Not Allowed), 404 — all indicate TCP+HTTP is working.
            if let http = response as? HTTPURLResponse {
                lastSuccessAt = Date()
                lastError = nil
                if !isServerReachable {
                    Self.logger.info("Server reachable (\(reason.rawValue), HTTP \(http.statusCode), \(elapsed)ms)")
                    activity.log(.network, "Server reachable (\(reason.rawValue), \(elapsed)ms)")
                }
                consecutiveProbeFailures = 0
                isServerReachable = true
            }
        } catch {
            consecutiveProbeFailures += 1
            lastError = error.localizedDescription

            Self.logger.warning("Probe failed (\(reason.rawValue)) #\(self.consecutiveProbeFailures): \(error.localizedDescription)")

            if consecutiveProbeFailures >= Self.failureThreshold && isServerReachable {
                isServerReachable = false
                activity.log(.error, "Server unreachable after \(self.consecutiveProbeFailures) probe failures: \(error.localizedDescription)")
            }
        }
    }
}
