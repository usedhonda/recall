import Foundation
import OSLog

final class BackgroundUploadService: NSObject, Sendable {
    static let shared = BackgroundUploadService()

    private static let logger = Logger(subsystem: "com.recai", category: "BackgroundUploadService")
    private static let backgroundIdentifier = "com.recai.background-upload"

    private let foregroundSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

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
    func backgroundUpload(fileURL: URL, to serverURL: URL, metadata: [String: String]) throws {
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

        Self.logger.info("Background uploading \(fileName) (\(fileData.count) bytes)")
        getBackgroundSession().uploadTask(with: request, fromFile: tempURL).resume()
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
