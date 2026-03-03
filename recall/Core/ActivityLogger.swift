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
    private let udpQueue = DispatchQueue(label: "com.recall.udplog", qos: .utility)
    private nonisolated(unsafe) var udpConnection: NWConnection?
    private let udpPort: UInt16 = 9199

    // File persistence
    private let fileQueue = DispatchQueue(label: "com.recall.filelog", qos: .utility)
    private let logRetentionDays = 7
    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {
        setupUDP()
        cleanupOldLogs()
    }

    func log(_ category: Entry.Category, _ message: String) {
        let entry = Entry(timestamp: Date(), category: category, message: message)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        sendUDP(entry.formatted)
        writeToFile(entry)
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

    // MARK: - File Persistence

    private nonisolated var logsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("logs", isDirectory: true)
    }

    private nonisolated func logFileURL(for date: Date) -> URL {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        return logsDirectory.appendingPathComponent("activity_\(df.string(from: date)).log")
    }

    private func writeToFile(_ entry: Entry) {
        let line = "\(iso8601.string(from: entry.timestamp)) [\(entry.category.rawValue)] \(entry.message)\n"
        let url = logFileURL(for: entry.timestamp)

        fileQueue.async { [logsDir = self.logsDirectory] in
            let fm = FileManager.default
            if !fm.fileExists(atPath: logsDir.path) {
                try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            }

            if fm.fileExists(atPath: url.path) {
                if let handle = try? FileHandle(forWritingTo: url) {
                    handle.seekToEndOfFile()
                    handle.write(line.data(using: .utf8) ?? Data())
                    handle.closeFile()
                }
            } else {
                try? line.data(using: .utf8)?.write(to: url)
            }
        }
    }

    private nonisolated func cleanupOldLogs() {
        fileQueue.async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let dir = self.logsDirectory
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }

            let cutoff = Date().addingTimeInterval(-Double(self.logRetentionDays) * 86400)
            for file in files {
                guard file.lastPathComponent.hasPrefix("activity_") else { continue }
                if let attrs = try? fm.attributesOfItem(atPath: file.path),
                   let created = attrs[.creationDate] as? Date,
                   created < cutoff {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }
}
