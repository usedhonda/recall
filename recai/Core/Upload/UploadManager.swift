import Foundation
import Observation
import OSLog
import SwiftData

@Observable
@MainActor
final class UploadManager {
    private(set) var isUploading = false
    private(set) var uploadProgress = ""
    private(set) var pendingCount = 0
    private(set) var uploadedCount = 0
    private(set) var failedCount = 0

    private var shouldContinue = false
    private var processingTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.recai", category: "UploadManager")
    private static let maxBackoffSeconds: TimeInterval = 300

    private let uploadService = BackgroundUploadService.shared

    func startProcessing(modelContext: ModelContext) {
        guard !isUploading else { return }
        shouldContinue = true
        isUploading = true
        Self.logger.info("Upload processing started")

        processingTask = Task { [weak self] in
            await self?.processLoop(modelContext: modelContext)
        }
    }

    func stopProcessing() {
        shouldContinue = false
        processingTask?.cancel()
        processingTask = nil
        isUploading = false
        uploadProgress = ""
        Self.logger.info("Upload processing stopped")
    }

    func retryFailed(modelContext: ModelContext) {
        let failed = AudioChunk.UploadStatus.failed.rawValue
        let predicate = #Predicate<AudioChunk> { $0.uploadStatusRaw == failed }
        let descriptor = FetchDescriptor<AudioChunk>(predicate: predicate)

        do {
            let failedChunks = try modelContext.fetch(descriptor)
            for chunk in failedChunks {
                chunk.uploadStatus = .pending
                chunk.uploadAttempts = 0
                chunk.lastUploadAttempt = nil
            }
            try modelContext.save()
            Self.logger.info("Reset \(failedChunks.count) failed chunks to pending")
        } catch {
            Self.logger.error("Failed to reset failed chunks: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func processLoop(modelContext: ModelContext) async {
        while shouldContinue, !Task.isCancelled {
            // Check connectivity
            guard ConnectivityMonitor.shared.canUpload else {
                uploadProgress = "Waiting for network..."
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            // Refresh counts
            refreshCounts(modelContext: modelContext)

            // Fetch next pending chunk
            guard let chunk = fetchNextPending(modelContext: modelContext) else {
                uploadProgress = pendingCount == 0 ? "All uploads complete" : ""
                try? await Task.sleep(for: .seconds(3))
                continue
            }

            // Check backoff for previously failed attempts
            if chunk.uploadAttempts > 0, let lastAttempt = chunk.lastUploadAttempt {
                let backoff = min(pow(2.0, Double(chunk.uploadAttempts)), Self.maxBackoffSeconds)
                let elapsed = Date().timeIntervalSince(lastAttempt)
                if elapsed < backoff {
                    let remaining = Int(backoff - elapsed)
                    uploadProgress = "Backoff: retry in \(remaining)s"
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
            }

            await uploadChunk(chunk, modelContext: modelContext)
        }

        isUploading = false
        uploadProgress = ""
    }

    private func uploadChunk(_ chunk: AudioChunk, modelContext: ModelContext) async {
        let settings = AppSettings.shared
        guard let serverURL = URL(string: settings.uploadServerURL + "/ingest") else {
            Self.logger.error("Invalid upload server URL: \(settings.uploadServerURL)")
            uploadProgress = "Invalid server URL"
            return
        }

        let fileURL = URL(fileURLWithPath: chunk.filePath)
        guard FileManager.default.fileExists(atPath: chunk.filePath) else {
            Self.logger.warning("Chunk file missing: \(chunk.filePath), marking as failed")
            chunk.uploadStatus = .failed
            try? modelContext.save()
            return
        }

        // Build metadata
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let metadata: [String: String] = [
            "device_id": settings.deviceId,
            "started_at": formatter.string(from: chunk.startedAt),
            "timezone": TimeZone.current.identifier
        ]

        chunk.uploadStatus = .uploading
        try? modelContext.save()
        uploadProgress = "Uploading \(chunk.fileName)..."
        Self.logger.info("Uploading chunk: \(chunk.fileName)")

        do {
            let recordingId = try await uploadService.upload(
                fileURL: fileURL,
                to: serverURL,
                metadata: metadata
            )

            chunk.uploadStatus = .uploaded
            chunk.uploadedAt = Date()
            try? modelContext.save()

            // Delete local file after successful upload
            try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)

            refreshCounts(modelContext: modelContext)
            uploadProgress = "Uploaded \(chunk.fileName)"
            Self.logger.info("Chunk uploaded: \(chunk.fileName) -> \(recordingId)")
        } catch {
            chunk.uploadStatus = .failed
            chunk.uploadAttempts += 1
            chunk.lastUploadAttempt = Date()
            try? modelContext.save()

            refreshCounts(modelContext: modelContext)
            uploadProgress = "Failed: \(chunk.fileName)"
            Self.logger.error("Upload failed for \(chunk.fileName): \(error.localizedDescription)")
        }
    }

    private func fetchNextPending(modelContext: ModelContext) -> AudioChunk? {
        let pending = AudioChunk.UploadStatus.pending.rawValue
        let predicate = #Predicate<AudioChunk> { $0.uploadStatusRaw == pending }
        var descriptor = FetchDescriptor<AudioChunk>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        descriptor.fetchLimit = 1

        return try? modelContext.fetch(descriptor).first
    }

    func refreshCounts(modelContext: ModelContext) {
        let pendingVal = AudioChunk.UploadStatus.pending.rawValue
        let uploadedVal = AudioChunk.UploadStatus.uploaded.rawValue
        let failedVal = AudioChunk.UploadStatus.failed.rawValue

        let pendingPredicate = #Predicate<AudioChunk> { $0.uploadStatusRaw == pendingVal }
        let uploadedPredicate = #Predicate<AudioChunk> { $0.uploadStatusRaw == uploadedVal }
        let failedPredicate = #Predicate<AudioChunk> { $0.uploadStatusRaw == failedVal }

        pendingCount = (try? modelContext.fetchCount(FetchDescriptor<AudioChunk>(predicate: pendingPredicate))) ?? 0
        uploadedCount = (try? modelContext.fetchCount(FetchDescriptor<AudioChunk>(predicate: uploadedPredicate))) ?? 0
        failedCount = (try? modelContext.fetchCount(FetchDescriptor<AudioChunk>(predicate: failedPredicate))) ?? 0
    }
}
