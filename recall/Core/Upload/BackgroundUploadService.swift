import Foundation
import OSLog

final class BackgroundUploadService: NSObject, @unchecked Sendable {
    static let shared = BackgroundUploadService()

    private static let logger = Logger(subsystem: "com.recall", category: "BackgroundUploadService")
    private static let backgroundIdentifier = "com.recall.background-upload"
    private static let stateDirectoryName = "BackgroundUploadState"
    private static let pendingUploadsFileName = "pending-uploads.json"
    private static let completedUploadsFileName = "completed-uploads.json"
    private static let reconcileGraceSeconds: TimeInterval = 15

    private let foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()
    private let stateQueue = DispatchQueue(label: "com.recall.background-upload.state")

    // Background session for when the app is backgrounded
    private var backgroundSession: URLSession?

    private func getBackgroundSession() -> URLSession {
        if let session = backgroundSession { return session }
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        backgroundSession = session
        return session
    }

    nonisolated(unsafe) private var backgroundCompletionHandler: (() -> Void)?

    private override init() {
        super.init()
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    /// Initialize the background session (call on app launch to reconnect to pending transfers)
    func initializeBackgroundSession() {
        _ = getBackgroundSession()
    }

    func activeBackgroundChunkIDs() async -> Set<UUID> {
        let tasks = await getBackgroundSession().allTasks
        return Set(tasks.compactMap { task in
            guard let description = task.taskDescription else { return nil }
            return UUID(uuidString: description)
        })
    }

    func backgroundUploadSnapshot(now: Date = Date()) async -> BackgroundUploadSnapshot {
        let activeChunkIDs = await activeBackgroundChunkIDs()
        let activeStrings = Set(activeChunkIDs.map(\.uuidString))

        return stateQueue.sync {
            var pending = loadPendingUploadsLocked()
            var didPrune = false

            for (key, record) in pending {
                guard let chunkID = UUID(uuidString: key) else {
                    if let removed = pending.removeValue(forKey: key) {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: removed.tempFilePath))
                    }
                    didPrune = true
                    continue
                }

                guard !activeStrings.contains(key) else { continue }
                let queuedAt = record.queuedAt ?? now
                guard now.timeIntervalSince(queuedAt) >= Self.reconcileGraceSeconds else { continue }

                if let removed = pending.removeValue(forKey: key) {
                    Self.logger.warning("Pruned stale background upload record: \(chunkID.uuidString)")
                    try? FileManager.default.removeItem(at: URL(fileURLWithPath: removed.tempFilePath))
                }
                didPrune = true
            }

            if didPrune {
                savePendingUploadsLocked(pending)
            }

            return BackgroundUploadSnapshot(
                activeChunkIDs: activeChunkIDs,
                pendingChunkIDs: Set(pending.keys.compactMap(UUID.init(uuidString:)))
            )
        }
    }

    func drainCompletedUploads() -> [CompletedBackgroundUpload] {
        stateQueue.sync {
            let outcomes = loadCompletedUploadsLocked()
            saveCompletedUploadsLocked([])
            return outcomes
        }
    }

    /// Upload an audio file to the VoiceLog server.
    /// - Parameters:
    ///   - fileURL: Local URL of the audio chunk file
    ///   - serverURL: VoiceLog /ingest endpoint URL
    ///   - metadata: Dictionary containing device_id, started_at, timezone
    /// - Returns: The recording_id from the server response
    func upload(fileURL: URL, to serverURL: URL, metadata: [String: String]) async throws -> String {
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent

        // Build metadata JSON
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        guard let metadataString = String(data: metadataJSON, encoding: .utf8) else {
            throw UploadError.invalidMetadata
        }

        // Build multipart body
        var form = MultipartFormData()
        form.addFile(name: "file", fileName: fileName, mimeType: "audio/mp4", data: fileData)
        form.addField(name: "metadata", value: metadataString)

        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        let body = form.build()

        Self.logger.info("Uploading \(fileName) (\(fileData.count) bytes) to \(serverURL.absoluteString)")

        // Use foreground session with async API
        let (data, response) = try await foregroundSession.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "no body"
            Self.logger.error("Upload failed: HTTP \(httpResponse.statusCode) - \(body)")
            throw UploadError.serverError(statusCode: httpResponse.statusCode, message: body)
        }

        // Parse recording_id from response
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let recordingId = json?["recording_id"] as? String else {
            throw UploadError.missingRecordingId
        }

        Self.logger.info("Upload complete: \(fileName) -> recording_id=\(recordingId)")
        return recordingId
    }

    /// Upload using background session (writes multipart body to temp file)
    func backgroundUpload(chunkID: UUID, fileURL: URL, to serverURL: URL, metadata: [String: String]) throws {
        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent

        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        guard let metadataString = String(data: metadataJSON, encoding: .utf8) else {
            throw UploadError.invalidMetadata
        }

        var form = MultipartFormData()
        form.addFile(name: "file", fileName: fileName, mimeType: "audio/mp4", data: fileData)
        form.addField(name: "metadata", value: metadataString)

        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

        // Write body to temp file for background upload
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("multipart")
        let body = form.build()
        try body.write(to: tempURL)

        let task = getBackgroundSession().uploadTask(with: request, fromFile: tempURL)
        task.taskDescription = chunkID.uuidString
        stateQueue.sync {
            var pending = loadPendingUploadsLocked()
            pending[chunkID.uuidString] = PendingBackgroundUpload(
                chunkID: chunkID.uuidString,
                tempFilePath: tempURL.path,
                queuedAt: Date()
            )
            savePendingUploadsLocked(pending)
        }

        Self.logger.info("Background uploading \(fileName) (\(fileData.count) bytes)")
        task.resume()
    }

    private func recordCompletion(for task: URLSessionTask, error: Error?) {
        guard let chunkID = task.taskDescription, !chunkID.isEmpty else { return }

        stateQueue.sync {
            var pending = loadPendingUploadsLocked()
            let pendingRecord = pending.removeValue(forKey: chunkID)
            savePendingUploadsLocked(pending)

            if let pendingRecord {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: pendingRecord.tempFilePath))
            }

            var completed = loadCompletedUploadsLocked()
            let outcome: CompletedBackgroundUpload
            if let error {
                outcome = CompletedBackgroundUpload(
                    chunkID: chunkID,
                    status: .failed,
                    detail: error.localizedDescription,
                    completedAt: Date()
                )
            } else if let response = task.response as? HTTPURLResponse {
                if (200...299).contains(response.statusCode) {
                    outcome = CompletedBackgroundUpload(
                        chunkID: chunkID,
                        status: .uploaded,
                        detail: "HTTP \(response.statusCode)",
                        completedAt: Date()
                    )
                } else {
                    outcome = CompletedBackgroundUpload(
                        chunkID: chunkID,
                        status: .failed,
                        detail: "HTTP \(response.statusCode)",
                        completedAt: Date()
                    )
                }
            } else {
                outcome = CompletedBackgroundUpload(
                    chunkID: chunkID,
                    status: .failed,
                    detail: "invalid response",
                    completedAt: Date()
                )
            }

            completed.append(outcome)
            saveCompletedUploadsLocked(completed)
        }
    }

    private static var stateDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(stateDirectoryName, isDirectory: true)
    }

    private static var pendingUploadsURL: URL {
        stateDirectoryURL.appendingPathComponent(pendingUploadsFileName)
    }

    private static var completedUploadsURL: URL {
        stateDirectoryURL.appendingPathComponent(completedUploadsFileName)
    }

    private func ensureStateDirectoryLocked() {
        try? FileManager.default.createDirectory(
            at: Self.stateDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func loadPendingUploadsLocked() -> [String: PendingBackgroundUpload] {
        ensureStateDirectoryLocked()
        guard let data = try? Data(contentsOf: Self.pendingUploadsURL) else { return [:] }
        return (try? JSONDecoder().decode([String: PendingBackgroundUpload].self, from: data)) ?? [:]
    }

    private func savePendingUploadsLocked(_ uploads: [String: PendingBackgroundUpload]) {
        ensureStateDirectoryLocked()
        let data = try? JSONEncoder().encode(uploads)
        try? data?.write(to: Self.pendingUploadsURL, options: .atomic)
    }

    private func loadCompletedUploadsLocked() -> [CompletedBackgroundUpload] {
        ensureStateDirectoryLocked()
        guard let data = try? Data(contentsOf: Self.completedUploadsURL) else { return [] }
        return (try? JSONDecoder().decode([CompletedBackgroundUpload].self, from: data)) ?? []
    }

    private func saveCompletedUploadsLocked(_ uploads: [CompletedBackgroundUpload]) {
        ensureStateDirectoryLocked()
        let data = try? JSONEncoder().encode(uploads)
        try? data?.write(to: Self.completedUploadsURL, options: .atomic)
    }
}

// MARK: - URLSessionDelegate

extension BackgroundUploadService: URLSessionDelegate, URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            Self.logger.error("Background upload failed: \(error.localizedDescription)")
        } else {
            Self.logger.info("Background upload task completed")
        }
        recordCompletion(for: task, error: error)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Self.logger.info("Background session finished events")
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    func urlSession(
        _ session: URLSession,
        didBecomeInvalidWithError error: Error?
    ) {
        if let error {
            Self.logger.error("Background session invalidated: \(error.localizedDescription)")
        }
    }
}

// MARK: - UploadError

struct CompletedBackgroundUpload: Codable {
    enum Status: String, Codable {
        case uploaded
        case failed
    }

    let chunkID: String
    let status: Status
    let detail: String
    let completedAt: Date
}

private struct PendingBackgroundUpload: Codable {
    let chunkID: String
    let tempFilePath: String
    let queuedAt: Date?
}

struct BackgroundUploadSnapshot {
    let activeChunkIDs: Set<UUID>
    let pendingChunkIDs: Set<UUID>
}

enum UploadError: LocalizedError {
    case invalidMetadata
    case invalidResponse
    case serverError(statusCode: Int, message: String)
    case missingRecordingId

    var errorDescription: String? {
        switch self {
        case .invalidMetadata:
            "Failed to encode upload metadata"
        case .invalidResponse:
            "Server returned an invalid response"
        case .serverError(let code, let message):
            "Server error (HTTP \(code)): \(message)"
        case .missingRecordingId:
            "Server response missing recording_id"
        }
    }
}
