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

    // UI dedupe — collapse identical (category, message) within window to prevent
    // on-screen spam (e.g., repeated `[H] Error: HTTP 404`). UDP and file logs are
    // always sent in full so the off-device debug trail stays complete.
    private var recentUIMessages: [String: Date] = [:]
    private let dedupeWindow: TimeInterval = 30

    // Remote log via UDP broadcast
    private let udpQueue = DispatchQueue(label: "com.recall.udplog", qos: .utility)
    private var udpConnection: NWConnection?
    private let udpPort: UInt16 = 9199

    // File persistence
    private let fileQueue = DispatchQueue(label: "com.recall.filelog", qos: .utility)
    private let logRetentionDays = 7

    // Buffered writer state — touched ONLY on `fileQueue` (serial), so the
    // `nonisolated(unsafe)` access is race-free. Always-on recording emits
    // several log lines/second; opening+closing a FileHandle per line tripped
    // iOS's `diskwrites_resource` flag. Instead we hold one handle open per
    // day-file and batch lines, flushing on a short timer / size threshold /
    // immediately for errors so the post-mortem trail keeps the lines that matter.
    // `nonisolated(unsafe)` (matching `udpConnection`): on this @Observable class
    // the qualifier also excludes these from observation tracking, which plain
    // `nonisolated` cannot do for a mutable stored property. Safe because every
    // access happens on the serial `fileQueue`.
    private nonisolated(unsafe) var fileHandle: FileHandle?
    private nonisolated(unsafe) var openLogURL: URL?
    private nonisolated(unsafe) var pendingBuffer = Data()
    private nonisolated(unsafe) var flushScheduled = false
    private let flushInterval: TimeInterval = 2.0
    private let flushThresholdBytes = 16 * 1024

    private let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {
        setupUDP()
        cleanupOldLogs()
    }

    /// Reports how long the log had been silent before this process started.
    ///
    /// iOS never tells an app that it was killed, so a termination leaves no trace of its
    /// own: the only evidence is the hole in the log, and finding one means reading the
    /// file by hand afterwards. On 2026-09-12 the app was gone for 5h04m and nobody
    /// noticed until the numbers were pulled two days later. Nothing else in the app
    /// matters while the process is absent — no location, no health, no greeting — so
    /// every launch now says out loud how long the silence was.
    ///
    /// Must be called before anything else writes, or it measures its own line.
    func noteProcessStart() {
        let newest = (try? FileManager.default.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ))?
            .filter { $0.lastPathComponent.hasPrefix("activity_") }
            .compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }
            .max()

        guard let newest else {
            log(.state, "Process start: no earlier log (first run or logs cleared)")
            return
        }
        let minutes = Int(Date().timeIntervalSince(newest) / 60)
        log(.state, "Process start: log had been silent for \(minutes) min")
    }

    func log(_ category: Entry.Category, _ message: String) {
        let entry = Entry(timestamp: Date(), category: category, message: message)

        sendUDP(entry.formatted)
        writeToFile(entry)

        if Self.shouldSuppressUI(message: message) {
            return
        }

        let key = "\(category.rawValue):\(message)"
        let now = entry.timestamp
        if let last = recentUIMessages[key], now.timeIntervalSince(last) < dedupeWindow {
            return
        }
        recentUIMessages[key] = now
        if recentUIMessages.count > 100 {
            let cutoff = now.addingTimeInterval(-dedupeWindow * 2)
            recentUIMessages = recentUIMessages.filter { $0.value > cutoff }
        }

        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private static func shouldSuppressUI(message: String) -> Bool {
        // Hide backend transport errors (e.g. HTTP 404/5xx) — these are server-side
        // outages the user can't act on. UDP and file logs still capture them so
        // remote debugging stays intact.
        message.contains("HTTP 4") || message.contains("HTTP 5")
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

    private func sendUDP(_ text: String) {
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
        guard let data = line.data(using: .utf8) else { return }
        let url = logFileURL(for: entry.timestamp)
        // Errors are flushed immediately so a crash/kill never drops the line
        // that explains it. Routine lines are batched (see `enqueue`).
        let flushNow = entry.category == .error
        fileQueue.async { [weak self] in
            self?.enqueue(data, for: url, flushNow: flushNow)
        }
    }

    /// Appends one line to the in-memory buffer and decides when it reaches
    /// disk. Runs on `fileQueue`. On a day rollover the previous handle is
    /// flushed and closed before the new file's handle is opened.
    private nonisolated func enqueue(_ data: Data, for url: URL, flushNow: Bool) {
        if openLogURL != url {
            flushBuffer()
            closeHandle()
        }
        ensureHandleOpen(url)
        pendingBuffer.append(data)
        if flushNow || pendingBuffer.count >= flushThresholdBytes {
            flushBuffer()
        } else {
            scheduleFlush()
        }
    }

    /// Opens (and seeks to end of) the day-file handle if not already open.
    private nonisolated func ensureHandleOpen(_ url: URL) {
        if fileHandle != nil, openLogURL == url { return }
        let fm = FileManager.default
        let dir = logsDirectory
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
        openLogURL = url
    }

    /// Writes any buffered bytes to the open handle in a single write.
    private nonisolated func flushBuffer() {
        guard !pendingBuffer.isEmpty, let handle = fileHandle else { return }
        try? handle.write(contentsOf: pendingBuffer)
        pendingBuffer.removeAll(keepingCapacity: true)
    }

    private nonisolated func closeHandle() {
        try? fileHandle?.close()
        fileHandle = nil
        openLogURL = nil
    }

    /// Schedules a single deferred flush; coalesces bursts so we write at most
    /// once per `flushInterval` instead of once per line.
    private nonisolated func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        fileQueue.asyncAfter(deadline: .now() + flushInterval) { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushBuffer()
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
