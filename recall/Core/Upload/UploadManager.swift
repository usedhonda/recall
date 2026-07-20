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
    private var consecutiveFailures = 0
    private var lastHealthLog: Date = .distantPast

    private let uploadService = BackgroundUploadService.shared
    private let activity = ActivityLogger.shared

    func startProcessing(modelContext: ModelContext) {
        guard !isUploading else { return }
        shouldContinue = true
        isUploading = true
        uploadService.initializeBackgroundSession()
        let serverURL = AppSettings.shared.uploadServerURL
        Self.logger.info("Upload processing started")
        activity.log(.upload, "Upload queue started (server: \(serverURL.isEmpty ? "NOT SET" : serverURL))")

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
            guard ConnectivityMonitor.shared.canUploadAudio else {
                let cm = ConnectivityMonitor.shared
                let reason: String
                if !cm.isConnected {
                    reason = "offline"
                } else if cm.isCellular && AppSettings.shared.dataPolicy != .any {
                    reason = "cellular (wifi policy)"
                } else if cm.isExpensive {
                    reason = "expensive network"
                } else {
                    reason = "network unavailable"
                }
                uploadProgress = "Waiting: \(reason)"
                // Log once per minute when blocked
                if Int(Date().timeIntervalSince1970) % 60 == 0 {
                    activity.log(.upload, "Upload blocked: \(reason) pending=\(pendingCount)")
                }
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            // Refresh counts
            refreshCounts(modelContext: modelContext)

            // Reset uploads stuck in .uploading with stale lastUploadAttempt
            resetStaleUploads(modelContext: modelContext)

            // Drop chunks older than 10 minutes — stale audio has no value
            dropStaleChunks(modelContext: modelContext)

            // Auto-retry failed chunks every 60s
            autoRetryFailed(modelContext: modelContext)

            // Global backoff: pause when server is unreachable
            if consecutiveFailures >= 3 {
                let pauseSec = consecutiveFailures >= 5 ? 60 : 30
                activity.log(.upload, "Server unreachable (\(consecutiveFailures) failures), pausing \(pauseSec)s")
                try? await Task.sleep(for: .seconds(pauseSec))
                consecutiveFailures = 0 // reset after pause to allow retry
                continue
            }

            // Periodic queue health summary (every 5 min)
            if Date().timeIntervalSince(lastHealthLog) >= 300 {
                lastHealthLog = Date()
                activity.log(.upload, "Queue health: pending=\(pendingCount) failed=\(failedCount) uploaded=\(uploadedCount)")
            }

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
                chunk.uploadStatus = .uploaded
                chunk.uploadedAt = Date()
                try? modelContext.save()
                try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
                refreshCounts(modelContext: modelContext)
                continue
            }

            // Skip noise-only chunks: no sustained voice detected
            if chunk.maxContinuousVoiceMs < 200 && chunk.voiceFrameRatio < 0.05 {
                Self.logger.info("Skipping noise chunk: \(chunk.fileName) (mcv=\(chunk.maxContinuousVoiceMs)ms vfr=\(chunk.voiceFrameRatio, format: .fixed(precision: 2)))")
                activity.log(.upload, "Skipped noise chunk \(chunk.fileName) (mcv=\(chunk.maxContinuousVoiceMs)ms vfr=\(String(format: "%.2f", chunk.voiceFrameRatio)))")
                chunk.uploadStatus = .uploaded
                chunk.uploadedAt = Date()
                try? modelContext.save()
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

        // Skip zero-byte files (corrupted encoder output)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: chunk.filePath)[.size] as? Int) ?? 0
        if fileSize == 0 {
            activity.log(.upload, "Skipped 0-byte chunk \(chunk.fileName)")
            chunk.uploadStatus = .uploaded
            try? modelContext.save()
            try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
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

        // Server optimization hints
        metadata["is_speech"] = "true" // iOS VAD confirmed speech — server can skip VAD
        metadata["chunk_start_utc"] = formatter.string(from: chunk.startedAt) // absolute timestamp for offset
        metadata["language"] = "ja" // language hint — server can skip detection
        metadata["reaction_mode"] = settings.reactionMode.rawValue // Chi reaction stance (auto/question/rebut/executive); latest chunk wins server-side

        // Location metadata (attach current position to audio chunk)
        if let location = TelemetryService.shared.locationManager.currentLocation {
            metadata["latitude"] = String(format: "%.6f", location.coordinate.latitude)
            metadata["longitude"] = String(format: "%.6f", location.coordinate.longitude)
            metadata["location_accuracy"] = String(format: "%.1f", location.horizontalAccuracy)
        }

        chunk.uploadStatus = .uploading
        chunk.lastUploadAttempt = Date()
        try? modelContext.save()

        // Always use foreground session — recall's audio background mode keeps
        // the process alive, so background URLSession is unnecessary and adds
        // failure modes (ATS edge cases, stuck tasks, delegate timing).
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
            consecutiveFailures = 0
            ServerHealthMonitor.shared.recordUploadSuccess()
        } catch {
            consecutiveFailures += 1
            chunk.uploadStatus = .failed
            chunk.uploadAttempts += 1
            chunk.lastUploadAttempt = Date()
            try? modelContext.save()

            refreshCounts(modelContext: modelContext)
            let reason = Self.classifyUploadError(error)
            uploadProgress = "Failed: \(reason)"
            Self.logger.error("Upload failed for \(chunk.fileName): \(reason) — \(error.localizedDescription)")
            activity.log(.error, "Upload FAIL \(chunk.fileName) #\(chunk.uploadAttempts) [\(reason)] \(error.localizedDescription)")
            ServerHealthMonitor.shared.recordUploadFailure(reason)

            // Log cumulative failure stats periodically
            if chunk.uploadAttempts == 1 || chunk.uploadAttempts % 5 == 0 {
                activity.log(.upload, "Upload stats: pending=\(pendingCount) failed=\(failedCount) attempt=#\(chunk.uploadAttempts) reason=\(reason)")
            }
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

    // MARK: - Stale Chunk Cleanup

    private static let maxChunkAgeSeconds: TimeInterval = 600 // 10 minutes
    private var lastStaleCheck: Date = .distantPast

    private func dropStaleChunks(modelContext: ModelContext) {
        // Check every 30s
        guard Date().timeIntervalSince(lastStaleCheck) >= 30 else { return }
        lastStaleCheck = Date()

        let cutoff = Date().addingTimeInterval(-Self.maxChunkAgeSeconds)
        let pending = AudioChunk.UploadStatus.pending.rawValue
        let failed = AudioChunk.UploadStatus.failed.rawValue
        let predicate = #Predicate<AudioChunk> {
            ($0.uploadStatusRaw == pending || $0.uploadStatusRaw == failed)
            && $0.startedAt < cutoff
        }
        let descriptor = FetchDescriptor<AudioChunk>(predicate: predicate)
        guard let stale = try? modelContext.fetch(descriptor), !stale.isEmpty else { return }

        for chunk in stale {
            chunk.uploadStatus = .uploaded // mark done to prevent retry
            Task { try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath) }
        }
        try? modelContext.save()
        activity.log(.upload, "Dropped \(stale.count) stale chunks (>10min old)")
    }

    // MARK: - Auto-Retry

    private var lastAutoRetry: Date = .distantPast

    private static let maxUploadAttempts = 10

    private func autoRetryFailed(modelContext: ModelContext) {
        guard Date().timeIntervalSince(lastAutoRetry) >= 60 else { return }
        lastAutoRetry = Date()

        let failed = AudioChunk.UploadStatus.failed.rawValue
        let predicate = #Predicate<AudioChunk> { $0.uploadStatusRaw == failed }
        let descriptor = FetchDescriptor<AudioChunk>(predicate: predicate)

        guard let failedChunks = try? modelContext.fetch(descriptor), !failedChunks.isEmpty else { return }
        var retried = 0
        var dropped = 0
        for chunk in failedChunks {
            if chunk.uploadAttempts >= Self.maxUploadAttempts {
                // Permanently skip — too many failures
                chunk.uploadStatus = .uploaded // mark as "done" to stop retrying
                activity.log(.upload, "Dropped after \(chunk.uploadAttempts) attempts: \(chunk.fileName)")
                dropped += 1
            } else {
                chunk.uploadStatus = .pending
                chunk.lastUploadAttempt = nil
                retried += 1
            }
        }
        try? modelContext.save()
        if retried > 0 {
            activity.log(.upload, "Auto-retry \(retried) failed -> pending (dropped \(dropped))")
        } else if dropped > 0 {
            activity.log(.upload, "Dropped \(dropped) permanently failed chunks")
        }
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

    // MARK: - Error Classification

    private static func classifyUploadError(_ error: Error) -> String {
        let nsError = error as NSError
        switch nsError.code {
        case NSURLErrorTimedOut:
            return "timeout"
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "unreachable"
        case NSURLErrorNetworkConnectionLost:
            return "connection-lost"
        case NSURLErrorNotConnectedToInternet:
            return "offline"
        case NSURLErrorDNSLookupFailed:
            return "dns-fail"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "tls-error"
        default:
            if nsError.domain == NSURLErrorDomain {
                return "network-\(nsError.code)"
            }
            // Check for HTTP status code errors
            let desc = error.localizedDescription.lowercased()
            if desc.contains("500") || desc.contains("502") || desc.contains("503") {
                return "server-error"
            }
            return "unknown"
        }
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
