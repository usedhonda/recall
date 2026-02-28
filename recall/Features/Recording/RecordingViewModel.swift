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

    func start(modelContainer: ModelContainer) async {
        do {
            if engine == nil {
                engine = AudioRecordingEngine()
                engine?.setModelContainer(modelContainer)
            }
            try await engine?.start()
            errorMessage = nil
            logger.info("Recording started")
            syncSharedState()
        } catch {
            errorMessage = error.localizedDescription
            logger.error("Failed to start: \(error)")
        }
    }

    func stop() {
        engine?.stop()
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
