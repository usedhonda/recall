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
    private var recoveredPersistedQueue = false
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
        if !recoveredPersistedQueue {
            do {
                try recoverPersistedQueue(context: ModelContext(modelContainer))
                recoveredPersistedQueue = true
            } catch {
                activity.log(.error, "[media] startup recovery could not be saved; queue retained")
                return
            }
        }
        shouldContinue = true
        isUploading = true
        Self.logger.info("MediaUploadManager started")
        activity.log(.upload, "[media] queue started")

        processingTask = Task { [weak self] in
            await self?.cleanupHubAckedFiles(modelContainer: modelContainer)
            await self?.processLoop(modelContainer: modelContainer)
        }
    }

    /// Ephemeral transfers cannot survive a process restart. Restore their queue
    /// ownership once per process, and repair retained paths after a container move.
    /// A missing replacement never authorizes deletion or a successful delivery.
    @discardableResult
    func recoverPersistedQueue(context: ModelContext, mediaDirectory: URL? = nil) throws -> Int {
        let directory = mediaDirectory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("media", isDirectory: true)
        let uploaded = MediaUploadStatus.uploaded.rawValue
        let rows = try context.fetch(FetchDescriptor<MediaChunk>(predicate: #Predicate { $0.uploadStatusRaw != uploaded }))
        var recovered = 0
        for chunk in rows {
            var changed = false
            if !FileManager.default.fileExists(atPath: chunk.filePath),
               !chunk.fileName.isEmpty, chunk.fileName != ".", chunk.fileName != "..",
               URL(fileURLWithPath: chunk.fileName).lastPathComponent == chunk.fileName {
                let candidate = directory.appendingPathComponent(chunk.fileName)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    chunk.filePath = candidate.path
                    changed = true
                }
            }
            if chunk.uploadStatus == .uploading {
                chunk.uploadStatus = .pending
                chunk.uploadedAt = nil
                changed = true
            }
            if changed { recovered += 1 }
        }
        if recovered > 0 {
            try context.save()
            activity.log(.upload, "[media] recovered \(recovered) retained queue records")
        }
        return recovered
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
            Self.logger.error("[media] invalid server URL; queue retained")
            // This is a configuration failure, not an attempt against this file.
            // Leave retry ownership intact without spinning on the same row.
            try? await Task.sleep(for: .seconds(10))
            return
        }
        let serverURL = baseURL.appendingPathComponent("ingest-media")

        let fileURL = URL(fileURLWithPath: chunk.filePath)
        let fileData: Data
        do {
            // Missing files follow the same counted/backed-off failure path as
            // other read errors; an existence check must not bypass that path.
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
                        throw CocoaError(.fileReadCorruptFile)
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
        nextPendingChunk(context: context, hubEnabled: HubDeliveryService.shared.isEnabled(.glassesOriginal))
    }

    /// Optional dates are filtered in memory: a #Predicate that force-unwraps
    /// `lastUploadAttempt` throws `unsupportedPredicate`, which `try?` turned into
    /// "nothing pending".
    func nextPendingChunk(context: ModelContext, hubEnabled: Bool) -> MediaChunk? {
        let pending = MediaUploadStatus.pending.rawValue
        let failed = MediaUploadStatus.failed.rawValue
        let attemptCap = hubEnabled ? Int.max : Self.maxAttempts
        let descriptor = FetchDescriptor<MediaChunk>(
            predicate: #Predicate<MediaChunk> {
                ($0.uploadStatusRaw == pending || $0.uploadStatusRaw == failed) && $0.uploadAttempts < attemptCap
            },
            sortBy: [SortDescriptor(\.capturedAt, order: .forward)])
        let rows: [MediaChunk]
        do {
            rows = try context.fetch(descriptor)
        } catch {
            ActivityLogger.shared.log(.error, "[media] pending fetch failed: \(error.localizedDescription)")
            return nil
        }
        guard hubEnabled else { return rows.first }
        let retryBefore = Date().addingTimeInterval(-5)
        return rows
            .filter { ($0.lastUploadAttempt ?? .distantPast) < retryBefore }
            .min { ($0.lastUploadAttempt ?? .distantPast) < ($1.lastUploadAttempt ?? .distantPast) }
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
