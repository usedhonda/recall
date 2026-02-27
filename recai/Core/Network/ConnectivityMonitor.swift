import Foundation
import Network
import Observation

@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private(set) var isConnected = false
    private(set) var isWiFi = false
    private(set) var isCellular = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.recai.connectivity", qos: .utility)

    private init() {}

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let cellular = path.usesInterfaceType(.cellular)
            Task { @MainActor in
                let changed = self.isConnected != connected || self.isWiFi != wifi || self.isCellular != cellular
                self.isConnected = connected
                self.isWiFi = wifi
                self.isCellular = cellular
                if changed {
                    let net = wifi ? "WiFi" : cellular ? "Cellular" : connected ? "Other" : "None"
                    ActivityLogger.shared.log(.network, "Network: \(net)")
                }
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }

    var canUpload: Bool {
        guard isConnected else { return false }
        if AppSettings.shared.wifiOnlyUpload {
            return isWiFi
        }
        return true
    }
}
