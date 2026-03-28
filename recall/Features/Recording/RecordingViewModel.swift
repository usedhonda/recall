import Foundation
import Observation
import SwiftData
import WidgetKit
import OSLog

@Observable
@MainActor
final class RecordingViewModel {
    private let logger = Logger(subsystem: "com.recall", category: "RecordingVM")

    var engine: AudioRecordingEngine?
    var isRecording: Bool { engine?.state == .recording }
    var isListening: Bool { engine?.state == .listening }
    var isActive: Bool { engine?.state != .idle }
    var currentRMS: Float { engine?.currentRMS ?? 0 }
    var vadProbability: Float { engine?.vadProbability ?? 0 }
    var state: AudioRecordingEngine.RecordingState { engine?.state ?? .idle }
    var chunksRecorded: Int { engine?.chunksRecorded ?? 0 }
    var currentChunkDuration: TimeInterval { engine?.currentChunkDuration ?? 0 }
    var errorMessage: String?

    private let maxStartRetries = 3
    private var retryTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?

    func start(modelContainer: ModelContainer) async {
        for attempt in 1...maxStartRetries {
            do {
                if engine == nil {
                    engine = AudioRecordingEngine()
                    engine?.setModelContainer(modelContainer)
                }
                try await engine?.start()
                errorMessage = nil
                logger.info("Recording started")

                // Resume upload queue if not already running
                if !UploadManager.shared.isUploading {
                    let context = ModelContext(modelContainer)
                    UploadManager.shared.startProcessing(modelContext: context)
                }

                syncSharedState()
                startHealthMonitor(modelContainer: modelContainer)
                return
            } catch {
                logger.error("Engine start attempt \(attempt)/\(self.maxStartRetries) failed: \(error)")
                ActivityLogger.shared.log(.error, "ENGINE start failed (#\(attempt)): \(error)")
                if attempt < maxStartRetries {
                    // Reset engine for fresh retry
                    engine?.stop()
                    engine = nil
                    try? await Task.sleep(for: .seconds(2))
                } else {
                    errorMessage = error.localizedDescription
                    // Keep retrying in background every 10s
                    scheduleBackgroundRetry(modelContainer: modelContainer)
                }
            }
        }
    }

    private func scheduleBackgroundRetry(modelContainer: ModelContainer) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                guard self.engine?.state == .idle else { return } // recovered
                attempt += 1
                ActivityLogger.shared.log(.state, "Background retry #\(attempt)")
                self.engine?.stop()
                self.engine = nil
                self.engine = AudioRecordingEngine()
                self.engine?.setModelContainer(modelContainer)
                do {
                    try await self.engine?.start()
                    self.errorMessage = nil
                    ActivityLogger.shared.log(.state, "Background retry #\(attempt) SUCCESS")
                    if !UploadManager.shared.isUploading {
                        let context = ModelContext(modelContainer)
                        UploadManager.shared.startProcessing(modelContext: context)
                    }
                    self.syncSharedState()
                    self.startHealthMonitor(modelContainer: modelContainer)
                    return
                } catch {
                    ActivityLogger.shared.log(.error, "Background retry #\(attempt) failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Upper-level health monitor — independent of engine's internal watchdog.
    /// Detects engine death that the watchdog couldn't recover from and recreates the engine entirely.
    private func startHealthMonitor(modelContainer: ModelContainer) {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }

                guard let engine = self.engine else {
                    ActivityLogger.shared.log(.error, "HealthMonitor: engine is nil — recreating")
                    await self.start(modelContainer: modelContainer)
                    return
                }

                if engine.state == .idle && !engine.userStopped {
                    ActivityLogger.shared.log(.error, "HealthMonitor: engine idle (not user-stopped) — full recreate")
                    self.engine?.stop()
                    self.engine = nil
                    await self.start(modelContainer: modelContainer)
                    return
                }
            }
        }
    }

    func stop() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        retryTask?.cancel()
        retryTask = nil
        engine?.stop()
        UploadManager.shared.stopProcessing()
        logger.info("Recording stopped")
        syncSharedState()
    }

    func syncSharedState() {
        RecordingStateManager.shared.isRecording = isActive
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(
                ofKind: "com.example.recall.RecordingControl"
            )
        }
    }

    func handleExternalToggle(modelContainer: ModelContainer) async {
        let desired = RecordingStateManager.shared.isRecording
        let current = isActive

        guard desired != current else { return }

        if desired {
            logger.info("External toggle: starting recording")
            await start(modelContainer: modelContainer)
        } else {
            logger.info("External toggle: stopping recording")
            stop()
        }
    }
}
