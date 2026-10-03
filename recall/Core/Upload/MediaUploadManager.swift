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
        guard !isUploading else { return }
        shouldContinue = true
        isUploading = true
        Self.logger.info("MediaUploadManager started")
        activity.log(.upload, "[media] queue started")

        processingTask = Task { [weak self] in
            await self?.cleanupHubAckedFiles(modelContainer: modelContainer)
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
                if pendingCount == 0 && !(HubDeliveryService.shared.isEnabled(.glassesOriginal) && failedCount > 0) {
                    isUploading = false
                    return
                }
                try? await Task.sleep(for: .seconds(3))
                continue
            }

            // Honor backoff for failed chunks
            if !HubDeliveryService.shared.isEnabled(.glassesOriginal), chunk.uploadAttempts > 0, let last = chunk.lastUploadAttempt {
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

    private func uploadChunk(_ chunk: MediaChunk, context: ModelContext, preserveForHub: Bool = false) async {
        if chunk.source == .glasses && HubDeliveryService.shared.isEnabled(.glassesOriginal) && !preserveForHub {
            await uploadHubOriginal(chunk, context: context)
            return
        }
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

            if preserveForHub {
                chunk.legacyUploadedAt = Date()
                chunk.uploadStatus = .pending
                chunk.uploadedAt = nil
            } else {
                chunk.uploadStatus = .uploaded
                chunk.uploadedAt = Date()
            }
            try context.save()
            if !preserveForHub { try FileManager.default.removeItem(at: fileURL) }
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

    private func uploadHubOriginal(_ chunk: MediaChunk, context: ModelContext) async {
        let hub = HubDeliveryService.shared
        do {
            if chunk.hubAcknowledgedAt == nil {
                if chunk.hubExternalID == nil {
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: chunk.filePath))
                    guard !bytes.isEmpty else {
                        await hub.recordGap(route: .glassesOriginal, reason: "empty_original")
                        return
                    }
                    let metadata = buildMetadata(chunk: chunk, deviceId: AppSettings.shared.deviceId)
                    chunk.hubExternalID = try await hub.admit(route: .glassesOriginal,
                        observationID: chunk.id.uuidString.lowercased(), occurredAt: chunk.capturedAt,
                        timeBasis: "captured_at", sourcePayloadJSON: JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
                        originalBytes: bytes)
                    chunk.hubAdmittedAt = Date()
                    try context.save()
                }
                if let id = chunk.hubExternalID, try await hub.isAcknowledged(externalID: id) {
                    chunk.hubAcknowledgedAt = Date()
                    try context.save()
                }
            }
            if !hub.legacyDisabled(.glassesOriginal) && chunk.legacyUploadedAt == nil {
                await uploadChunk(chunk, context: context, preserveForHub: true)
            }
            if chunk.hubAcknowledgedAt != nil && (hub.legacyDisabled(.glassesOriginal) || chunk.legacyUploadedAt != nil) {
                chunk.uploadStatus = .uploaded
                chunk.uploadedAt = Date()
                try context.save()
                try FileManager.default.removeItem(atPath: chunk.filePath)
            }
        } catch {
            chunk.uploadStatus = .failed
            chunk.uploadedAt = nil
            try? context.save()
            await hub.recordGap(route: .glassesOriginal, reason: "original_delivery_failed")
        }
        chunk.lastUploadAttempt = Date()
        chunk.uploadAttempts = max(1, chunk.uploadAttempts)
        try? context.save()
        refreshCounts(context: context)
        try? await Task.sleep(for: .seconds(1))
    }

    private func cleanupHubAckedFiles(modelContainer: ModelContainer) async {
        let context = ModelContext(modelContainer)
        let uploadedRaw = MediaUploadStatus.uploaded.rawValue
        let descriptor = FetchDescriptor<MediaChunk>(predicate: #Predicate {
            $0.hubAcknowledgedAt != nil && $0.uploadStatusRaw == uploadedRaw
        })
        guard let chunks = try? context.fetch(descriptor) else { return }
        for chunk in chunks {
            guard FileManager.default.fileExists(atPath: chunk.filePath) else { continue }
            try? FileManager.default.removeItem(atPath: chunk.filePath)
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
        let hubEnabled = HubDeliveryService.shared.isEnabled(.glassesOriginal)
        let attemptCap = hubEnabled ? Int.max : Self.maxAttempts
        let retryBefore = hubEnabled ? Date().addingTimeInterval(-5) : Date.distantFuture
        let predicate = #Predicate<MediaChunk> {
            ($0.uploadStatusRaw == pending || $0.uploadStatusRaw == failed) && $0.uploadAttempts < attemptCap
            && ($0.lastUploadAttempt == nil || $0.lastUploadAttempt! < retryBefore)
        }
        var descriptor = FetchDescriptor<MediaChunk>(predicate: predicate,
            sortBy: hubEnabled ? [SortDescriptor(\.lastUploadAttempt, order: .forward)] : [SortDescriptor(\.capturedAt, order: .forward)])
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
        var dropped = 0
        for chunk in expired where chunk.source != .glasses || !HubDeliveryService.shared.isEnabled(.glassesOriginal) {
            try? FileManager.default.removeItem(atPath: chunk.filePath)
            context.delete(chunk)
            dropped += 1
        }
        try? context.save()
        if dropped > 0 { activity.log(.upload, "[media] dropped \(dropped) expired chunks (>7d)") }
    }
}
