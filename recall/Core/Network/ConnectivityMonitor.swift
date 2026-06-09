import Foundation
import Network
import Observation

@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private(set) var isConnected = false
    private(set) var isWiFi = false
    private(set) var isCellular = false
    private(set) var isExpensive = false
    private(set) var isConstrained = false

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
                let changed = self.isConnected != connected || self.isWiFi != wifi
                    || self.isCellular != cellular || self.isExpensive != expensive
                    || self.isConstrained != constrained
                self.isConnected = connected
                self.isWiFi = wifi
                self.isCellular = cellular
                self.isExpensive = expensive
                self.isConstrained = constrained
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
