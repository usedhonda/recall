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
                }
            }
        }
    }

    func stop() {
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
