import Foundation
import Observation
import OSLog
import SwiftData

@Observable
@MainActor
final class MediaUploadManager {
    static let shared = MediaUploadManager()

    private(set) var isUploading = false
    private(set) var pendingCount = 0
    private(set) var uploadedCount = 0
    private(set) var failedCount = 0
    private(set) var lastUploadProgress = ""

    private static let logger = Logger(subsystem: "com.recall", category: "MediaUploadManager")
    private static let maxBackoffSeconds: TimeInterval = 300
    private static let retentionDays: TimeInterval = 7
    private static let maxAttempts = 10

    private var processingTask: Task<Void, Never>?
    private var shouldContinue = false
    private let activity = ActivityLogger.shared
    private var consecutiveFailures = 0

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    private init() {}

    func startProcessing(modelContainer: ModelContainer) {
        guard !LaunchContext.shouldStaySilent else {
            activity.log(.upload, "[media] silent launch: queue not started")
            return
        }
        guard !isUploading else { return }
        shouldContinue = true
        isUploading = true
        Self.logger.info("MediaUploadManager started")
        activity.log(.upload, "[media] queue started")

        processingTask = Task { [weak self] in
            await self?.processLoop(modelContainer: modelContainer)
        }
    }

    func stopProcessing() {
        shouldContinue = false
        processingTask?.cancel()
        processingTask = nil
        isUploading = false
        activity.log(.upload, "[media] queue stopped")
    }

    private func processLoop(modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        while shouldContinue, !Task.isCancelled {
            guard ConnectivityMonitor.shared.canUploadAudio else {
                try? await Task.sleep(for: .seconds(10))
                continue
            }

            refreshCounts(context: context)
            dropExpired(context: context)

            if consecutiveFailures >= 3 {
                let pause = consecutiveFailures >= 5 ? 60 : 30
                activity.log(.upload, "[media] server unreachable (\(consecutiveFailures) failures), pausing \(pause)s")
                try? await Task.sleep(for: .seconds(pause))
                consecutiveFailures = 0
                continue
            }

            guard let chunk = fetchNextPending(context: context) else {
                if pendingCount == 0 {
                    isUploading = false
                    return
                }
                try? await Task.sleep(for: .seconds(3))
                continue
            }

            // Honor backoff for failed chunks
            if chunk.uploadAttempts > 0, let last = chunk.lastUploadAttempt {
                let backoff = min(pow(2.0, Double(chunk.uploadAttempts)), Self.maxBackoffSeconds)
                let elapsed = Date().timeIntervalSince(last)
                if elapsed < backoff {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
            }

            await uploadChunk(chunk, context: context)
        }
        isUploading = false
    }

    private func uploadChunk(_ chunk: MediaChunk, context: ModelContext) async {
        let settings = AppSettings.shared
        guard let baseURL = URL(string: settings.uploadServerURL),
              let scheme = baseURL.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              baseURL.host != nil else {
            Self.logger.error("[media] invalid server URL: \(settings.uploadServerURL)")
            return
        }
        let serverURL = baseURL.appendingPathComponent("ingest-media")

        guard FileManager.default.fileExists(atPath: chunk.filePath) else {
            chunk.uploadStatus = .failed
            try? context.save()
            return
        }
        let fileURL = URL(fileURLWithPath: chunk.filePath)
        let fileData: Data
        do {
            fileData = try Data(contentsOf: fileURL)
        } catch {
            activity.log(.error, "[media] read failed \(chunk.fileName): \(error.localizedDescription)")
            chunk.uploadStatus = .failed
            chunk.uploadAttempts += 1
            chunk.lastUploadAttempt = Date()
            try? context.save()
            return
        }
        if fileData.isEmpty {
            activity.log(.upload, "[media] skipping 0-byte chunk \(chunk.fileName)")
            chunk.uploadStatus = .uploaded
            try? context.save()
            try? FileManager.default.removeItem(at: fileURL)
            return
        }

        let metadata = buildMetadata(chunk: chunk, deviceId: settings.deviceId)
        let mimeType = mimeType(for: chunk)

        chunk.uploadStatus = .uploading
        chunk.lastUploadAttempt = Date()
        try? context.save()

        do {
            let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
            guard let metadataString = String(data: metadataJSON, encoding: .utf8) else {
                throw UploadError.invalidMetadata
            }
            var form = MultipartFormData()
            form.addFile(name: "file", fileName: chunk.fileName, mimeType: mimeType, data: fileData)
            form.addField(name: "metadata", value: metadataString)

            var request = URLRequest(url: serverURL)
            request.httpMethod = "POST"
            request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")

            let body = form.build()
            activity.log(.upload, "[media] uploading \(chunk.fileName) (\(fileData.count) B) -> \(serverURL.absoluteString)")
            let (data, response) = try await session.upload(for: request, from: body)

            guard let http = response as? HTTPURLResponse else {
                throw UploadError.invalidResponse
            }
            guard (200...299).contains(http.statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? ""
                throw UploadError.serverError(statusCode: http.statusCode, message: bodyStr)
            }

            chunk.uploadStatus = .uploaded
            chunk.uploadedAt = Date()
            try? context.save()
            try? FileManager.default.removeItem(at: fileURL)
            consecutiveFailures = 0
            refreshCounts(context: context)
            activity.log(.upload, "[media] uploaded \(chunk.fileName) HTTP \(http.statusCode)")
        } catch {
            consecutiveFailures += 1
            chunk.uploadStatus = .failed
            chunk.uploadAttempts += 1
            chunk.lastUploadAttempt = Date()
            try? context.save()
            refreshCounts(context: context)
            activity.log(.error, "[media] upload FAIL \(chunk.fileName) #\(chunk.uploadAttempts) \(error.localizedDescription)")
        }
    }

    private func buildMetadata(chunk: MediaChunk, deviceId: String) -> [String: String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        var metadata: [String: String] = [
            "device_id": deviceId,
            "media_type": chunk.mediaTypeRaw,
            "captured_at": formatter.string(from: chunk.capturedAt),
            "imported_at": formatter.string(from: chunk.importedAt),
            "photo_local_id": chunk.photoLocalIdentifier,
            "exif_make": chunk.exifMake,
            "exif_model": chunk.exifModel,
            "uti": chunk.uti,
            "pixel_width": String(chunk.pixelWidth),
            "pixel_height": String(chunk.pixelHeight),
            "match_confidence": chunk.matchConfidenceRaw,
            "source": chunk.sourceRaw,
            "timezone": TimeZone.current.identifier
        ]
        if let lat = chunk.latitude { metadata["latitude"] = String(format: "%.6f", lat) }
        if let lon = chunk.longitude { metadata["longitude"] = String(format: "%.6f", lon) }
        if let dur = chunk.videoDurationSec { metadata["video_duration_sec"] = String(format: "%.3f", dur) }
        if let codec = chunk.videoCodec { metadata["video_codec"] = codec }
        if let frameRate = chunk.videoFrameRate { metadata["video_frame_rate"] = String(format: "%.3f", frameRate) }
        return metadata
    }

    private func mimeType(for chunk: MediaChunk) -> String {
        switch chunk.uti.lowercased() {
        case "public.heic", "public.heif": return "image/heic"
        case "public.jpeg": return "image/jpeg"
        case "public.png": return "image/png"
        case "public.mpeg-4": return "video/mp4"
        case "com.apple.quicktime-movie": return "video/quicktime"
        default: return chunk.mediaType == .video ? "video/mp4" : "image/heic"
        }
    }

    private func fetchNextPending(context: ModelContext) -> MediaChunk? {
        let pending = MediaUploadStatus.pending.rawValue
        let failed = MediaUploadStatus.failed.rawValue
        let attemptCap = Self.maxAttempts
        let predicate = #Predicate<MediaChunk> {
            ($0.uploadStatusRaw == pending || $0.uploadStatusRaw == failed) && $0.uploadAttempts < attemptCap
        }
        var descriptor = FetchDescriptor<MediaChunk>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func refreshCounts(context: ModelContext) {
        let pending = MediaUploadStatus.pending.rawValue
        let failed = MediaUploadStatus.failed.rawValue
        let uploaded = MediaUploadStatus.uploaded.rawValue
        pendingCount = (try? context.fetchCount(FetchDescriptor<MediaChunk>(predicate: #Predicate { $0.uploadStatusRaw == pending }))) ?? 0
        failedCount = (try? context.fetchCount(FetchDescriptor<MediaChunk>(predicate: #Predicate { $0.uploadStatusRaw == failed }))) ?? 0
        uploadedCount = (try? context.fetchCount(FetchDescriptor<MediaChunk>(predicate: #Predicate { $0.uploadStatusRaw == uploaded }))) ?? 0
    }

    private func dropExpired(context: ModelContext) {
        let pending = MediaUploadStatus.pending.rawValue
        let failed = MediaUploadStatus.failed.rawValue
        let cutoff = Date().addingTimeInterval(-Self.retentionDays * 24 * 3600)
        let predicate = #Predicate<MediaChunk> {
            ($0.uploadStatusRaw == pending || $0.uploadStatusRaw == failed) && $0.createdAt < cutoff
        }
        let descriptor = FetchDescriptor<MediaChunk>(predicate: predicate)
        guard let expired = try? context.fetch(descriptor), !expired.isEmpty else { return }
        for chunk in expired {
            try? FileManager.default.removeItem(atPath: chunk.filePath)
            context.delete(chunk)
        }
        try? context.save()
        activity.log(.upload, "[media] dropped \(expired.count) expired chunks (>7d)")
    }
}
