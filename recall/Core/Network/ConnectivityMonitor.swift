import Foundation
import Network
import NetworkExtension
import Observation

@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private(set) var isConnected = false
    private(set) var isWiFi = false
    private(set) var isCellular = false
    private(set) var isExpensive = false
    private(set) var isConstrained = false

    /// Derived home-Wi-Fi state: "home" (on the user-set home SSID), "away"
    /// (on a different Wi-Fi, or off Wi-Fi after any SSID was seen), or nil
    /// (feature disabled / state unknown). Only this derived value travels in
    /// telemetry — the raw SSID never leaves the device.
    private(set) var wifiContext: String?

    /// True once a real (non-nil) SSID has been observed. Gates the "away"
    /// classification on a Wi-Fi drop so probe failures don't fake a departure.
    private var hasSeenSSIDState = false

    /// Whether the app is currently in the foreground. Updated from RecallApp's
    /// scenePhase observer. Used by data saver mode: foreground = send all,
    /// background = send nothing. Initial false is correct for silent launch.
    var isAppActive = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.recall.connectivity", qos: .utility)
    private var lastNetworkInterfaceNames: Set<String> = []

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let cellular = path.usesInterfaceType(.cellular)
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                let wasWiFi = self.isWiFi
                let changed = self.isConnected != connected || self.isWiFi != wifi
                    || self.isCellular != cellular || self.isExpensive != expensive
                    || self.isConstrained != constrained
                self.isConnected = connected
                self.isWiFi = wifi
                self.isCellular = cellular
                self.isExpensive = expensive
                self.isConstrained = constrained

                self.updateWiFiContext(wifi: wifi, wasWiFi: wasWiFi)

                if changed {
                    var flags: [String] = []
                    if expensive { flags.append("expensive") }
                    if constrained { flags.append("lowdata") }
                    let suffix = flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]"
                    let net = wifi ? "WiFi" : cellular ? "Cellular" : connected ? "Other" : "None"
                    ActivityLogger.shared.log(.network, "Network: \(net)\(suffix)")
                }

                // Detect network interface changes (important for Tailscale VPN)
                let currentInterfaces = Set(path.availableInterfaces.map(\.name))
                if connected,
                   !self.lastNetworkInterfaceNames.isEmpty,
                   currentInterfaces != self.lastNetworkInterfaceNames {
                    let from = self.lastNetworkInterfaceNames.sorted().joined(separator: ",")
                    let to = currentInterfaces.sorted().joined(separator: ",")
                    ActivityLogger.shared.log(.network, "Interface changed: [\(from)] -> [\(to)]")
                    ServerHealthMonitor.shared.probeNow(reason: .networkChange)
                }
                self.lastNetworkInterfaceNames = currentInterfaces
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    // MARK: - Home Wi-Fi Context

    /// Recompute `wifiContext` from a path change. Only the HOME SSID's
    /// disconnect kicks a fresh GPS fix (owner constraint — GPS stays the
    /// source of truth, Wi-Fi is reinforcement only).
    @MainActor
    private func updateWiFiContext(wifi: Bool, wasWiFi: Bool) {
        // Feature disabled: no home SSID set -> no derived state, no kick.
        guard !AppSettings.shared.homeSSID.isEmpty else {
            hasSeenSSIDState = false
            applyWiFiContext(nil)
            return
        }

        if wifi {
            // Probe the SSID only on a Wi-Fi-connected transition. fetchCurrent
            // may return nil in background / without precise location: treat nil
            // as "unknown" and leave wifiContext untouched so a probe failure
            // never fakes a departure while still on Wi-Fi.
            guard !wasWiFi else { return }
            probeSSID { [weak self] ssid in
                Task { @MainActor in
                    guard let self else { return }
                    guard let ssid, !ssid.isEmpty else { return } // unknown -> keep current
                    self.hasSeenSSIDState = true
                    let home = AppSettings.shared.homeSSID
                    self.applyWiFiContext(ssid == home ? "home" : "away")
                }
            }
        } else {
            // Left Wi-Fi (cellular or none) — a real interface drop. Classify as
            // "away" only if we ever saw a real SSID; otherwise state is unknown.
            applyWiFiContext(hasSeenSSIDState ? "away" : nil)
        }
    }

    /// Set `wifiContext`, log the transition, and kick a fresh GPS fix when
    /// leaving home (home -> not-home).
    @MainActor
    private func applyWiFiContext(_ new: String?) {
        let previous = wifiContext
        guard previous != new else { return }
        wifiContext = new
        ActivityLogger.shared.log(.network, "wifi context: \(previous ?? "nil") -> \(new ?? "nil")")
        if previous == "home", new != "home" {
            TelemetryService.shared.locationManager.kickFreshFix(reason: "home wifi disconnect")
        }
    }

    /// Fetch the current Wi-Fi SSID via NEHotspotNetwork (needs the wifi-info
    /// entitlement + location auth). The callback fires on an arbitrary queue.
    private func probeSSID(_ completion: @escaping (String?) -> Void) {
        NEHotspotNetwork.fetchCurrent { network in
            completion(network?.ssid)
        }
    }

    // Single data policy gate. All streams (audio/health/location) follow the
    // same rule so the user picks one option instead of juggling four toggles.
    private var canSendNow: Bool {
        guard isConnected else { return false }
        switch AppSettings.shared.dataPolicy {
        case .any:            return true
        case .wifiOnly:       return isWiFi && !isExpensive && !isConstrained
        case .wifiForeground: return isWiFi && !isExpensive && !isConstrained && isAppActive
        }
    }

    var canUploadAudio: Bool { canSendNow }
    var canSendHealth: Bool { canSendNow }
    var canSendLocation: Bool { canSendNow }
}
