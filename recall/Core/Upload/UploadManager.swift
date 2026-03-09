import Foundation
import Observation
import OSLog
import SwiftData
import UIKit

@Observable
@MainActor
final class UploadManager {
    static let shared = UploadManager()

    private(set) var isUploading = false
    private(set) var uploadProgress = ""
    private(set) var pendingCount = 0
    private(set) var uploadedCount = 0
    private(set) var failedCount = 0

    private var shouldContinue = false
    private var processingTask: Task<Void, Never>?

    private static let logger = Logger(subsystem: "com.recall", category: "UploadManager")
    private static let maxBackoffSeconds: TimeInterval = 300

    private let uploadService = BackgroundUploadService.shared
    private let activity = ActivityLogger.shared

    func startProcessing(modelContext: ModelContext) {
        guard !isUploading else { return }
        shouldContinue = true
        isUploading = true
        uploadService.initializeBackgroundSession()
        Self.logger.info("Upload processing started")
        activity.log(.upload, "Upload queue started")

        processingTask = Task { [weak self] in
            await self?.reconcileUploadState(modelContext: modelContext)
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
        activity.log(.upload, "Upload queue stopped")
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

    // MARK: - Reconciliation

    /// Unconditionally reset all `.uploading` chunks to `.pending` on startup.
    /// Called before `startProcessing` to recover from app kill scenarios
    /// where no background session can vouch for the chunks.
    func reconcileStuckUploads(modelContext: ModelContext) {
        let uploading = AudioChunk.UploadStatus.uploading.rawValue
        let predicate = #Predicate<AudioChunk> { $0.uploadStatusRaw == uploading }
        let descriptor = FetchDescriptor<AudioChunk>(predicate: predicate)

        do {
            let stuck = try modelContext.fetch(descriptor)
            guard !stuck.isEmpty else { return }
            for chunk in stuck {
                chunk.uploadStatus = .pending
            }
            try modelContext.save()
            Self.logger.info("Reconciled \(stuck.count) stuck uploads -> pending")
            activity.log(.upload, "Reconciled \(stuck.count) stuck -> pending")
        } catch {
            Self.logger.error("Reconcile failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    private func processLoop(modelContext: ModelContext) async {
        while shouldContinue, !Task.isCancelled {
            await reconcileUploadState(modelContext: modelContext)

            // Check connectivity
            guard ConnectivityMonitor.shared.canUpload else {
                let cm = ConnectivityMonitor.shared
                if cm.isCellular {
                    uploadProgress = "Queuing (cellular)..."
                } else if !cm.isWiFi {
                    uploadProgress = "Waiting for WiFi..."
                } else {
                    uploadProgress = "Waiting for network..."
                }
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            // Refresh counts
            refreshCounts(modelContext: modelContext)

            // Reset uploads stuck in .uploading with stale lastUploadAttempt
            resetStaleUploads(modelContext: modelContext)

            // Fetch next pending chunk
            guard let chunk = fetchNextPending(modelContext: modelContext) else {
                uploadProgress = pendingCount == 0 ? "All uploads complete" : ""
                try? await Task.sleep(for: .seconds(3))
                continue
            }

            // Skip trivially short chunks (< 1.0s) — poor Whisper quality
            if chunk.duration < 1.0 {
                Self.logger.info("Skipping short chunk: \(chunk.fileName) (\(chunk.duration, format: .fixed(precision: 1))s < 1.0s)")
                activity.log(.upload, "Skipped short chunk \(chunk.fileName) (\(String(format: "%.1f", chunk.duration))s)")
                chunk.uploadStatus = .uploaded // Mark as done to skip permanently
                chunk.uploadedAt = Date()
                try? modelContext.save()
                // Delete the short file
                try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
                refreshCounts(modelContext: modelContext)
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
        guard let baseURL = URL(string: settings.uploadServerURL),
              let scheme = baseURL.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              baseURL.host != nil else {
            Self.logger.error("Invalid upload server URL: \(settings.uploadServerURL)")
            uploadProgress = "Invalid server URL"
            return
        }
        let serverURL = baseURL.appendingPathComponent("ingest")

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
        var metadata: [String: String] = [
            "device_id": settings.deviceId,
            "started_at": formatter.string(from: chunk.startedAt),
            "timezone": TimeZone.current.identifier
        ]

        // Audio quality metadata for voicelog filtering
        if chunk.avgRMS > 0 { metadata["avg_rms"] = String(format: "%.6f", chunk.avgRMS) }
        if chunk.vadAvgProb > 0 { metadata["vad_avg_prob"] = String(format: "%.4f", chunk.vadAvgProb) }
        if chunk.noiseFloorRMS > 0 { metadata["noise_floor_rms"] = String(format: "%.6f", chunk.noiseFloorRMS) }

        // Location metadata (attach current position to audio chunk)
        if let location = TelemetryService.shared.locationManager.currentLocation {
            metadata["latitude"] = String(format: "%.6f", location.coordinate.latitude)
            metadata["longitude"] = String(format: "%.6f", location.coordinate.longitude)
            metadata["location_accuracy"] = String(format: "%.1f", location.horizontalAccuracy)
        }

        chunk.uploadStatus = .uploading
        try? modelContext.save()

        let appState = UIApplication.shared.applicationState
        let shouldUseBackgroundSession = appState != .active

        if shouldUseBackgroundSession {
            do {
                try uploadService.backgroundUpload(
                    chunkID: chunk.id,
                    fileURL: fileURL,
                    to: serverURL,
                    metadata: metadata
                )
                refreshCounts(modelContext: modelContext)
                uploadProgress = "Queued \(chunk.fileName)..."
                Self.logger.info("Queued background upload: \(chunk.fileName)")
                activity.log(.upload, "Queued bg upload \(chunk.fileName)")
            } catch {
                chunk.uploadStatus = .failed
                chunk.uploadAttempts += 1
                chunk.lastUploadAttempt = Date()
                try? modelContext.save()

                refreshCounts(modelContext: modelContext)
                uploadProgress = "Failed: \(chunk.fileName)"
                Self.logger.error("Background queue failed for \(chunk.fileName): \(error.localizedDescription)")
                activity.log(.error, "BG queue failed: \(chunk.fileName) (#\(chunk.uploadAttempts)) \(error.localizedDescription)")
            }
            return
        }

        uploadProgress = "Uploading \(chunk.fileName)..."
        Self.logger.info("Uploading chunk: \(chunk.fileName)")
        activity.log(.upload, "Uploading \(chunk.fileName)")

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
            activity.log(.upload, "Uploaded \(chunk.fileName) -> \(recordingId)")
        } catch {
            chunk.uploadStatus = .failed
            chunk.uploadAttempts += 1
            chunk.lastUploadAttempt = Date()
            try? modelContext.save()

            refreshCounts(modelContext: modelContext)
            uploadProgress = "Failed: \(chunk.fileName)"
            Self.logger.error("Upload failed for \(chunk.fileName): \(error.localizedDescription)")
            activity.log(.error, "Upload failed: \(chunk.fileName) (#\(chunk.uploadAttempts)) \(error.localizedDescription)")
        }
    }

    /// Reset `.uploading` chunks whose `lastUploadAttempt` is older than 5 min.
    /// Catches in-flight uploads that stalled (e.g. app kill mid-upload).
    private func resetStaleUploads(modelContext: ModelContext) {
        let uploading = AudioChunk.UploadStatus.uploading.rawValue
        let staleThreshold = Date().addingTimeInterval(-300) // 5 min
        let predicate = #Predicate<AudioChunk> {
            $0.uploadStatusRaw == uploading && $0.lastUploadAttempt != nil && $0.lastUploadAttempt! < staleThreshold
        }
        let descriptor = FetchDescriptor<AudioChunk>(predicate: predicate)

        guard let stale = try? modelContext.fetch(descriptor), !stale.isEmpty else { return }
        for chunk in stale {
            chunk.uploadStatus = .pending
        }
        try? modelContext.save()
        Self.logger.info("Reset \(stale.count) stale uploads -> pending")
        activity.log(.upload, "Reset \(stale.count) stale -> pending")
    }

    private func reconcileUploadState(modelContext: ModelContext) async {
        let backgroundSnapshot = await uploadService.backgroundUploadSnapshot()

        var didChange = false
        let completedUploads = uploadService.drainCompletedUploads()
        for completed in completedUploads {
            guard let chunkID = UUID(uuidString: completed.chunkID),
                  let chunk = fetchChunk(id: chunkID, modelContext: modelContext) else {
                continue
            }

            switch completed.status {
            case .uploaded:
                chunk.uploadStatus = .uploaded
                chunk.uploadedAt = completed.completedAt
                try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
                activity.log(.upload, "BG uploaded \(chunk.fileName)")

            case .failed:
                chunk.uploadStatus = .failed
                chunk.uploadAttempts += 1
                chunk.lastUploadAttempt = completed.completedAt
                activity.log(.error, "BG upload failed: \(chunk.fileName) (#\(chunk.uploadAttempts)) \(completed.detail)")
            }
            didChange = true
        }

        let uploadingRaw = AudioChunk.UploadStatus.uploading.rawValue
        let uploadingDescriptor = FetchDescriptor<AudioChunk>(
            predicate: #Predicate<AudioChunk> { $0.uploadStatusRaw == uploadingRaw }
        )
        if let uploadingChunks = try? modelContext.fetch(uploadingDescriptor) {
            for chunk in uploadingChunks {
                if backgroundSnapshot.activeChunkIDs.contains(chunk.id) { continue }
                if backgroundSnapshot.pendingChunkIDs.contains(chunk.id) { continue }

                chunk.uploadStatus = .pending
                activity.log(.upload, "Recovered stale upload \(chunk.fileName) -> pending")
                didChange = true
            }
        }

        if didChange {
            try? modelContext.save()
            refreshCounts(modelContext: modelContext)
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

    private func fetchChunk(id: UUID, modelContext: ModelContext) -> AudioChunk? {
        let descriptor = FetchDescriptor<AudioChunk>(
            predicate: #Predicate<AudioChunk> { $0.id == id }
        )
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
