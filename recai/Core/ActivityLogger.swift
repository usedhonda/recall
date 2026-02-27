import Foundation
import Network
import Observation

@Observable
@MainActor
final class ActivityLogger {
    static let shared = ActivityLogger()

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let category: Category
        let message: String

        enum Category: String {
            case state = "STATE"
            case vad = "VAD"
            case chunk = "CHUNK"
            case upload = "UPLOAD"
            case network = "NET"
            case error = "ERROR"
            case health = "HEALTH"
            case location = "LOC"
            case telemetry = "TELE"

            var emoji: String {
                switch self {
                case .state: ">"
                case .vad: "#"
                case .chunk: "+"
                case .upload: "^"
                case .network: "~"
                case .error: "!"
                case .health: "H"
                case .location: "@"
                case .telemetry: "T"
                }
            }
        }

        var formatted: String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss"
            return "\(df.string(from: timestamp)) [\(category.emoji)] \(message)"
        }
    }

    private(set) var entries: [Entry] = []
    private let maxEntries = 200

    // Remote log via UDP broadcast
    private let udpQueue = DispatchQueue(label: "com.recai.udplog", qos: .utility)
    private nonisolated(unsafe) var udpConnection: NWConnection?
    private let udpPort: UInt16 = 9199

    private init() {
        setupUDP()
    }

    func log(_ category: Entry.Category, _ message: String) {
        let entry = Entry(timestamp: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        sendUDP(entry.formatted)
    }

    nonisolated func logFromBackground(_ category: Entry.Category, _ message: String) {
        Task { @MainActor in
            self.log(category, message)
        }
    }

    func clear() {
        entries.removeAll()
    }

    // MARK: - UDP Remote Logging

    private func setupUDP() {
        // Send to dev Mac's Tailscale IP
        let logHost = AppSettings.shared.debugLogHost
        guard !logHost.isEmpty else { return }
        let host = NWEndpoint.Host(logHost)
        let port = NWEndpoint.Port(rawValue: udpPort)!
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: host, port: port, using: params)
        conn.start(queue: udpQueue)
        udpConnection = conn
    }

    private nonisolated func sendUDP(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        udpConnection?.send(content: data, completion: .idempotent)
    }
}
