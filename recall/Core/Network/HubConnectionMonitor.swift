import Foundation
import Observation
import UIKit
import UserNotifications

enum HubConnectionIssue: Codable, Equatable {
    case unreachable(Int)
    case retrying(Int)
    case networkOther(Int)
    case secureConnection
    case rejected(Int)
    case receipt
    case configuration

    var title: String {
        switch self {
        case .unreachable: return "HUB UNREACHABLE"
        case .retrying: return "RETRYING UPLOAD"
        case .networkOther: return "HUB NETWORK ERROR"
        case .secureConnection: return "HUB SECURE CONNECTION FAILED"
        case .rejected(401), .rejected(403): return "HUB ACCESS REJECTED"
        case .rejected: return "HUB REQUEST REJECTED"
        case .receipt: return "HUB RECEIPT NOT VERIFIED"
        case .configuration: return "HUB CONFIGURATION UNAVAILABLE"
        }
    }

    var detail: String {
        switch self {
        case .unreachable(let code):
            let reason = code == URLError.timedOut.rawValue ? "Connection timed out." : "Connection failed."
            return "\(reason) Check that Tailscale is connected. Data is kept for retry."
        case .retrying:
            return "One upload is being retried. The Hub responded recently; queued data is retained."
        case .networkOther(let code):
            return "The network request failed (code \(code)). Data is kept for retry."
        case .secureConnection:
            return "The secure connection failed. Check the Hub certificate; data is kept for retry."
        case .rejected(let status):
            return "The network reached the server (HTTP \(status)). Check Hub access or server settings."
        case .receipt:
            return "The server responded without a verified receipt. Data is kept for retry."
        case .configuration:
            return "Hub settings could not be loaded. Data is kept for retry."
        }
    }

    var isRouteFailure: Bool {
        if case .unreachable = self { return true }
        return false
    }

    var isRetrying: Bool {
        if case .retrying = self { return true }
        return false
    }

    static func networkFailure(_ code: Int) -> Self? {
        switch code {
        case URLError.cancelled.rawValue: return nil
        case URLError.timedOut.rawValue, URLError.cannotFindHost.rawValue,
             URLError.cannotConnectToHost.rawValue, URLError.networkConnectionLost.rawValue,
             URLError.dnsLookupFailed.rawValue, URLError.notConnectedToInternet.rawValue:
            return .unreachable(code)
        case URLError.secureConnectionFailed.rawValue,
             URLError.serverCertificateHasBadDate.rawValue,
             URLError.serverCertificateUntrusted.rawValue,
             URLError.serverCertificateHasUnknownRoot.rawValue,
             URLError.serverCertificateNotYetValid.rawValue,
             URLError.clientCertificateRejected.rawValue,
             URLError.clientCertificateRequired.rawValue:
            return .secureConnection
        default: return .networkOther(code)
        }
    }
}

/// One latch shared by all lanes, persisted across relaunches. Neither a timer,
/// an interface change nor ordinary Internet reconnection re-arms the alert.
struct HubConnectionAlertState: Codable {
    /// One existing transport resource-timeout window of positive path evidence.
    static let recentResponseWindow: TimeInterval = 60
    var issue: HubConnectionIssue?
    var notificationClaimed = false
    var lastResponseAt: Date?

    mutating func failed(_ issue: HubConnectionIssue, attemptStartedAt: Date, at now: Date = Date()) {
        guard lastResponseAt.map({ attemptStartedAt > $0 }) ?? true else { return }
        if case .unreachable(let code) = issue, let last = lastResponseAt,
           (0..<Self.recentResponseWindow).contains(now.timeIntervalSince(last)) {
            self.issue = .retrying(code)
            return
        }
        self.issue = issue
    }

    mutating func responded(status: Int, at now: Date) {
        guard lastResponseAt.map({ now >= $0 }) ?? true else { return }
        lastResponseAt = now
        notificationClaimed = false
        issue = (200...299).contains(status) ? nil : .rejected(status)
    }

    mutating func claimNotification(networkAvailable: Bool) -> Bool {
        guard networkAvailable, issue?.isRouteFailure == true, !notificationClaimed else { return false }
        notificationClaimed = true
        return true
    }
}

@Observable
@MainActor
final class HubConnectionMonitor {
    static let shared = HubConnectionMonitor()
    private static let stateKey = "hub.connection-alert.v1"
    private static let notificationID = "recall.hub-connection-outage"
    private var state: HubConnectionAlertState
    private var notificationWorkInProgress = false
    private(set) var alertsEnabled = false
    private(set) var notificationSettingsRequired = false

    var issue: HubConnectionIssue? { state.issue }

    private init() {
        state = UserDefaults.standard.data(forKey: Self.stateKey)
            .flatMap { try? JSONDecoder().decode(HubConnectionAlertState.self, from: $0) }
            ?? HubConnectionAlertState()
    }

    func recordResponse(status: Int, at now: Date = Date()) {
        state.responded(status: status, at: now)
        persist()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }

    func recordFailure(_ issue: HubConnectionIssue, attemptStartedAt: Date) async {
        state.failed(issue, attemptStartedAt: attemptStartedAt)
        persist()
        await notifyIfNeeded()
    }

    func foreground() async {
        await refreshPermission()
        await notifyIfNeeded()
    }

    func enableAlerts() async {
        await refreshPermission()
        if notificationSettingsRequired {
            if let url = URL(string: UIApplication.openSettingsURLString) { await UIApplication.shared.open(url) }
            return
        }
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
        await refreshPermission()
        await notifyIfNeeded()
    }

    private func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        alertsEnabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        notificationSettingsRequired = settings.authorizationStatus == .denied
    }

    private func notifyIfNeeded() async {
        guard !notificationWorkInProgress, !state.notificationClaimed,
              state.issue?.isRouteFailure == true, ConnectivityMonitor.shared.isConnected else { return }
        notificationWorkInProgress = true
        defer { notificationWorkInProgress = false }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined,
           UIApplication.shared.applicationState == .active {
            _ = try? await center.requestAuthorization(options: [.alert])
        }
        await refreshPermission()
        guard alertsEnabled,
              state.claimNotification(networkAvailable: ConnectivityMonitor.shared.isConnected) else { return }
        // Persist the claim before scheduling, so a relaunch cannot repeat an
        // already submitted notification. No body, host or credential is stored.
        persist()
        let responseAt = state.lastResponseAt
        let content = UNMutableNotificationContent()
        content.title = "Check Tailscale connection"
        content.body = "A network connection is available, but recall cannot reach the Hub. Open Tailscale and check its connection. Data is kept for retry."
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        do {
            try await center.add(request)
            // A different lane may have recovered during the await.
            if state.lastResponseAt != responseAt {
                center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
                center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
            }
        } catch {
            if state.lastResponseAt == responseAt {
                state.notificationClaimed = false
                persist()
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: Self.stateKey) }
    }
}
