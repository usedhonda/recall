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
    private var lastBlockedLog: Date = .distantPast

    // Idle wait: instead of polling SwiftData every few seconds while there is
    // nothing to do, the loop sleeps until `wake()` (chunk saved / network
    // changed) or a 60 s fallback, whichever comes first.
    private static let idleFallbackSeconds: Double = 60
    private var idleWakeContinuation: CheckedContinuation<Void, Never>?
    private var idleWaitGeneration = 0

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
            await self?.cleanupHubAckedFiles(modelContext: modelContext)
            await self?.reconcileUploadState(modelContext: modelContext)
            await self?.processLoop(modelContext: modelContext)
        }
    }

    func stopProcessing() {
        shouldContinue = false
        processingTask?.cancel()
        processingTask = nil
        wake()
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
                chunk.discardReason = nil
                chunk.uploadedAt = nil
                chunk.uploadAttempts = 0
                chunk.lastUploadAttempt = nil
            }
            try modelContext.save()
            refreshCounts(modelContext: modelContext)
            Self.logger.info("Reset \(failedChunks.count) failed chunks to pending")
        } catch {
            Self.logger.error("Failed to reset failed chunks: \(error.localizedDescription)")
        }
    }

    // MARK: - Reconciliation

    /// Stored chunk paths are absolute and iOS can move the app's data container
    /// (new UUID) when the app is reinstalled. Re-point rows whose file now lives
    /// under the current chunks directory; without this every retained chunk fails
    /// to open and is never delivered.
    @discardableResult
    func repairMovedChunkPaths(modelContext: ModelContext, chunksDirectory: URL? = nil) -> Int {
        let directory = chunksDirectory ?? FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("chunks", isDirectory: true)
        let terminal = [AudioChunk.UploadStatus.uploaded.rawValue, AudioChunk.UploadStatus.discarded.rawValue]
        let descriptor = FetchDescriptor<AudioChunk>(predicate: #Predicate<AudioChunk> { !terminal.contains($0.uploadStatusRaw) })
        guard let rows = try? modelContext.fetch(descriptor) else { return 0 }
        var repaired = 0
        for chunk in rows where !FileManager.default.fileExists(atPath: chunk.filePath) {
            let candidate = directory.appendingPathComponent(chunk.fileName)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            chunk.filePath = candidate.path
            repaired += 1
        }
        if repaired > 0 {
            try? modelContext.save()
            activity.log(.upload, "Re-pointed \(repaired) chunk paths to the current data container")
        }
        return repaired
    }

    /// Unconditionally reset all `.uploading` chunks to `.pending` on startup.
    /// Called before `startProcessing` to recover from app kill scenarios
    /// where no background session can vouch for the chunks.
    func reconcileStuckUploads(modelContext: ModelContext) {
        repairMovedChunkPaths(modelContext: modelContext)
        let uploading = AudioChunk.UploadStatus.uploading.rawValue
        let predicate = #Predicate<AudioChunk> { $0.uploadStatusRaw == uploading }
        let descriptor = FetchDescriptor<AudioChunk>(predicate: predicate)

        do {
            let stuck = try modelContext.fetch(descriptor)
            guard !stuck.isEmpty else { return }
            for chunk in stuck {
                chunk.uploadStatus = .pending
                chunk.discardReason = nil
                chunk.uploadedAt = nil
            }
            try modelContext.save()
            refreshCounts(modelContext: modelContext)
            Self.logger.info("Reconciled \(stuck.count) stuck uploads -> pending")
            activity.log(.upload, "Reconciled \(stuck.count) stuck -> pending")
        } catch {
            Self.logger.error("Reconcile failed: \(error.localizedDescription)")
        }
    }

    /// Wake an idle queue loop immediately (new chunk saved, network changed).
    func wake() {
        idleWakeContinuation?.resume()
        idleWakeContinuation = nil
    }

    // MARK: - Private

    private func waitForWork() async {
        idleWaitGeneration += 1
        let generation = idleWaitGeneration
        await withCheckedContinuation { continuation in
            idleWakeContinuation = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.idleFallbackSeconds))
                guard let self, self.idleWaitGeneration == generation else { return }
                self.wake()
            }
        }
    }

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
                if Date().timeIntervalSince(lastBlockedLog) >= 60 {
                    lastBlockedLog = Date()
                    activity.log(.upload, "Upload blocked: \(reason) pending=\(pendingCount)")
                }
                await waitForWork()
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
                await waitForWork()
                continue
            }

            // Skip trivially short chunks (< 1.0s) — poor Whisper quality
            if chunk.duration < 1.0 && chunk.hubExternalID == nil {
                Self.logger.info("Skipping short chunk: \(chunk.fileName) (\(chunk.duration, format: .fixed(precision: 1))s < 1.0s)")
                activity.log(.upload, "Skipped short chunk \(chunk.fileName) (\(String(format: "%.1f", chunk.duration))s)")
                markDiscarded(chunk, reason: .short)
                try? modelContext.save()
                try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
                refreshCounts(modelContext: modelContext)
                continue
            }

            // Delete only audio that cannot contain a word. The owner's rule
            // (2026-09-13): truly meaningless audio may go, but nothing at a level where
            // speech could be leaking through — what the server can make of a marginal
            // recording will keep improving, and a deleted one is gone for good.
            //
            // An average can hide one word inside half a minute of quiet, so the peak
            // decides: unless no single frame of the whole chunk ever came near speech,
            // it is uploaded and the server judges it.
            if chunk.hubExternalID == nil && chunk.maxVadProb < 0.30 && chunk.maxContinuousVoiceMs < 200 && chunk.voiceFrameRatio < 0.05 {
                Self.logger.info("Skipping noise chunk: \(chunk.fileName) (mcv=\(chunk.maxContinuousVoiceMs)ms vfr=\(chunk.voiceFrameRatio, format: .fixed(precision: 2)))")
                activity.log(.upload, "Deleted silent chunk \(chunk.fileName) (peak=\(String(format: "%.2f", chunk.maxVadProb)) mcv=\(chunk.maxContinuousVoiceMs)ms vfr=\(String(format: "%.2f", chunk.voiceFrameRatio)))")
                markDiscarded(chunk, reason: .noise)
                try? modelContext.save()
                try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
                refreshCounts(modelContext: modelContext)
                continue
            }

            // Check backoff for previously failed attempts
            if !HubDeliveryService.shared.isEnabled(.audioOriginal), chunk.uploadAttempts > 0, let lastAttempt = chunk.lastUploadAttempt {
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

    private func uploadChunk(_ chunk: AudioChunk, modelContext: ModelContext, preserveForHub: Bool = false) async {
        if HubDeliveryService.shared.isEnabled(.audioOriginal) && !preserveForHub {
            await uploadHubOriginal(chunk, context: modelContext)
            return
        }
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
            chunk.discardReason = nil
            chunk.uploadedAt = nil
            try? modelContext.save()
            refreshCounts(modelContext: modelContext)
            return
        }

        // Skip zero-byte files (corrupted encoder output)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: chunk.filePath)[.size] as? Int) ?? 0
        if fileSize == 0 {
            activity.log(.upload, "Skipped 0-byte chunk \(chunk.fileName)")
            markDiscarded(chunk, reason: .empty)
            try? modelContext.save()
            try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
            refreshCounts(modelContext: modelContext)
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

        // What the detector measured over the whole chunk. The owner's rule is that the
        // device captures and the server judges: throwing audio away here forecloses any
        // processing anyone might want to do later, and the server can always ignore a
        // number it does not need.
        metadata["max_continuous_voice_ms"] = String(chunk.maxContinuousVoiceMs)
        metadata["voice_frame_ratio"] = String(format: "%.4f", chunk.voiceFrameRatio)
        metadata["max_vad_prob"] = String(format: "%.4f", chunk.maxVadProb)

        // Server optimization hints.
        // `is_speech` used to be hardcoded true, which told the server to skip its own
        // VAD on our word. On 2026-09-13 that word turned out to be worthless — chunks
        // with no speech in them scored the same as real ones — so it now reports what
        // was actually measured, and the server is free to check for itself.
        let sustainedVoice = chunk.maxContinuousVoiceMs >= 300 && chunk.voiceFrameRatio >= 0.10
        metadata["is_speech"] = sustainedVoice ? "true" : "false"
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
        chunk.discardReason = nil
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

            if preserveForHub {
                chunk.legacyUploadedAt = Date()
                chunk.uploadStatus = .pending
                chunk.uploadedAt = nil
            } else {
                markUploaded(chunk, at: Date())
            }
            try modelContext.save()
            if !preserveForHub { try await ChunkFileManager.shared.deleteChunk(at: chunk.filePath) }

            refreshCounts(modelContext: modelContext)
            uploadProgress = "Uploaded \(chunk.fileName)"
            Self.logger.info("Chunk uploaded: \(chunk.fileName) -> \(recordingId)")
            activity.log(.upload, "Uploaded \(chunk.fileName) -> \(recordingId)")
            consecutiveFailures = 0
            ServerHealthMonitor.shared.recordUploadSuccess()
        } catch {
            consecutiveFailures += 1
            chunk.uploadStatus = .failed
            chunk.discardReason = nil
            chunk.uploadedAt = nil
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

    /// Storage and legacy processing are separate durable outcomes.
    private func uploadHubOriginal(_ chunk: AudioChunk, context: ModelContext) async {
        let hub = HubDeliveryService.shared
        do {
            if chunk.hubAcknowledgedAt == nil {
                if chunk.hubExternalID == nil {
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: chunk.filePath))
                    guard !bytes.isEmpty else {
                        await hub.recordGap(route: .audioOriginal, reason: "empty_original")
                        return
                    }
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime]
                    var payload: [String: String] = [
                        "device_id": AppSettings.shared.deviceId,
                        "started_at": formatter.string(from: chunk.startedAt),
                        "chunk_start_utc": formatter.string(from: chunk.startedAt),
                        "duration_sec": String(chunk.duration),
                        "capture_time_known": "false", "capture_end_known": "false",
                        "capture_time_basis": "chunk_start_wall_clock_with_prepended_samples",
                        "duration_basis": "written_samples_divided_by_sample_rate",
                        "max_continuous_voice_ms": String(chunk.maxContinuousVoiceMs),
                        "voice_frame_ratio": String(format: "%.4f", chunk.voiceFrameRatio),
                        "max_vad_prob": String(format: "%.4f", chunk.maxVadProb)
                    ]
                    if chunk.avgRMS > 0 { payload["avg_rms"] = String(format: "%.6f", chunk.avgRMS) }
                    if chunk.vadAvgProb > 0 { payload["vad_avg_prob"] = String(format: "%.4f", chunk.vadAvgProb) }
                    if chunk.noiseFloorRMS > 0 { payload["noise_floor_rms"] = String(format: "%.6f", chunk.noiseFloorRMS) }
                    chunk.hubExternalID = try await hub.admit(route: .audioOriginal,
                        observationID: chunk.id.uuidString.lowercased(), occurredAt: chunk.startedAt,
                        timeBasis: "chunk_start_utc", sourcePayloadJSON: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                        originalBytes: bytes)
                    chunk.hubAdmittedAt = Date()
                    try context.save()
                }
                if let id = chunk.hubExternalID, try await hub.isAcknowledged(externalID: id) {
                    chunk.hubAcknowledgedAt = Date()
                    try context.save()
                }
            }
            // Expiration only suppresses stale legacy reactions, never storage.
            let fresh = Date().timeIntervalSince(chunk.startedAt) <= Self.maxChunkAgeSeconds
            if !hub.legacyDisabled(.audioOriginal) && fresh && chunk.legacyUploadedAt == nil {
                await uploadChunk(chunk, modelContext: context, preserveForHub: true)
            }
            if chunk.hubAcknowledgedAt != nil &&
                (hub.legacyDisabled(.audioOriginal) || !fresh || chunk.legacyUploadedAt != nil) {
                markUploaded(chunk, at: Date())
                try context.save()
                try await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
            }
        } catch {
            chunk.uploadStatus = .failed
            chunk.uploadedAt = nil
            chunk.lastUploadAttempt = Date()
            chunk.uploadAttempts += 1
            try? context.save()
            activity.log(.error, "Hub audio original \(chunk.fileName) failed: \(error)")
            await hub.recordGap(route: .audioOriginal, reason: "original_delivery_failed")
        }
        // Let other originals enter the durable outbox; never busy-loop one item.
        chunk.lastUploadAttempt = Date()
        chunk.uploadAttempts = max(1, chunk.uploadAttempts)
        try? context.save()
        refreshCounts(modelContext: context)
        try? await Task.sleep(for: .seconds(1))
    }

    /// Crash recovery: a durable ACK may have been saved immediately before a
    /// process kill, leaving the local file behind. Delete only after both the
    /// ACK and the model state are durable.
    private func cleanupHubAckedFiles(modelContext: ModelContext) async {
        let uploadedRaw = AudioChunk.UploadStatus.uploaded.rawValue
        let descriptor = FetchDescriptor<AudioChunk>(predicate: #Predicate {
            $0.hubAcknowledgedAt != nil && $0.uploadStatusRaw == uploadedRaw
        })
        guard let chunks = try? modelContext.fetch(descriptor) else { return }
        for chunk in chunks {
            guard FileManager.default.fileExists(atPath: chunk.filePath) else { continue }
            try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
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
            chunk.discardReason = nil
            chunk.uploadedAt = nil
        }
        try? modelContext.save()
        refreshCounts(modelContext: modelContext)
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

        var dropped = 0
        for chunk in stale where !HubDeliveryService.shared.isEnabled(.audioOriginal) {
            markDiscarded(chunk, reason: .expired)
            Task { try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath) }
            dropped += 1
        }
        try? modelContext.save()
        refreshCounts(modelContext: modelContext)
        if dropped > 0 { activity.log(.upload, "Dropped \(dropped) stale chunks (>10min old)") }
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
            if chunk.uploadAttempts >= Self.maxUploadAttempts && !HubDeliveryService.shared.isEnabled(.audioOriginal) {
                // Permanently skip — too many failures
                markDiscarded(chunk, reason: .retryExhausted)
                activity.log(.upload, "Dropped after \(chunk.uploadAttempts) attempts: \(chunk.fileName)")
                dropped += 1
            } else {
                chunk.uploadStatus = .pending
                chunk.discardReason = nil
                chunk.uploadedAt = nil
                chunk.lastUploadAttempt = nil
                retried += 1
            }
        }
        try? modelContext.save()
        refreshCounts(modelContext: modelContext)
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
                markUploaded(chunk, at: completed.completedAt)
                try? await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
                activity.log(.upload, "BG uploaded \(chunk.fileName)")

            case .failed:
                chunk.uploadStatus = .failed
                chunk.discardReason = nil
                chunk.uploadedAt = nil
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
                chunk.discardReason = nil
                chunk.uploadedAt = nil
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
        nextPendingChunk(modelContext: modelContext, hubEnabled: HubDeliveryService.shared.isEnabled(.audioOriginal))
    }

    func nextPendingChunk(modelContext: ModelContext, hubEnabled: Bool) -> AudioChunk? {
        // Filter the optional attempt date in memory: a nil-aware #Predicate over
        // `lastUploadAttempt` matched no rows and hid every pending chunk.
        let pending = AudioChunk.UploadStatus.pending.rawValue
        let descriptor = FetchDescriptor<AudioChunk>(
            predicate: #Predicate<AudioChunk> { $0.uploadStatusRaw == pending },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)])
        let rows: [AudioChunk]
        do {
            rows = try modelContext.fetch(descriptor)
        } catch {
            activity.log(.error, "Pending chunk fetch failed: \(error.localizedDescription)")
            return nil
        }
        guard hubEnabled else { return rows.first }
        let retryBefore = Date().addingTimeInterval(-5)
        return rows
            .filter { ($0.lastUploadAttempt ?? .distantPast) < retryBefore }
            .min { ($0.lastUploadAttempt ?? .distantPast) < ($1.lastUploadAttempt ?? .distantPast) }
    }

    private func fetchChunk(id: UUID, modelContext: ModelContext) -> AudioChunk? {
        let descriptor = FetchDescriptor<AudioChunk>(
            predicate: #Predicate<AudioChunk> { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    func markUploaded(_ chunk: AudioChunk, at date: Date) {
        chunk.uploadStatus = .uploaded
        chunk.discardReason = nil
        chunk.uploadedAt = date
    }

    func markDiscarded(_ chunk: AudioChunk, reason: AudioChunk.DiscardReason) {
        chunk.uploadStatus = .discarded
        chunk.discardReason = reason
        chunk.uploadedAt = nil
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
