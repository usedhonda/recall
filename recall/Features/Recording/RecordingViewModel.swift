import AVFoundation
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
    private var lastModelContainer: ModelContainer?
    var isRecording: Bool { engine?.state == .recording }
    var isListening: Bool { engine?.state == .listening }
    var isActive: Bool { engine?.state != .idle }
    var currentRMS: Float { engine?.currentRMS ?? 0 }
    var vadProbability: Float { engine?.vadProbability ?? 0 }
    var state: AudioRecordingEngine.RecordingState { engine?.state ?? .idle }
    var chunksRecorded: Int { engine?.chunksRecorded ?? 0 }
    var currentChunkDuration: TimeInterval { engine?.currentChunkDuration ?? 0 }
    var errorMessage: String?

    // MARK: - Mic Mode

    var currentMicMode: MicMode {
        AudioSessionManager.shared.desiredMicMode
    }

    func switchMicMode(_ mode: MicMode) async {
        let mgr = AudioSessionManager.shared
        mgr.setDesiredMicMode(mode)
        var appliedMode = mode

        do {
            // a. Reconfigure session with new mode
            try mgr.configure()

            // b. Select target input explicitly
            switch mode {
            case .builtIn:
                let builtIn = mgr.availableInputs.first { $0.portType == .builtInMic }
                try mgr.setPreferredInput(builtIn)

            case .bluetoothHFP:
                // BT HFP port may not appear immediately — retry
                var btPort: AVAudioSessionPortDescription?
                for _ in 0..<10 {
                    btPort = mgr.availableInputs.first { $0.portType == .bluetoothHFP }
                    if btPort != nil { break }
                    try await Task.sleep(for: .milliseconds(200))
                }
                if let btPort {
                    try mgr.setPreferredInput(btPort)
                } else {
                    // BT mic not found — fall back to built-in
                    appliedMode = .builtIn
                    mgr.setDesiredMicMode(.builtIn)
                    try mgr.configure()
                    let builtIn = mgr.availableInputs.first { $0.portType == .builtInMic }
                    try mgr.setPreferredInput(builtIn)
                    ActivityLogger.shared.log(.error, "BT mic not found — using built-in")
                }
            }

            // c. Persist
            AppSettings.shared.preferredMicMode = appliedMode.rawValue

            // d. Recreate engine to pick up new route
            if let container = lastModelContainer {
                engine?.stop()
                engine = nil
                engine = AudioRecordingEngine()
                engine?.setModelContainer(container)
                try await engine?.start()
            }

        } catch {
            logger.error("switchMicMode failed: \(error)")
            ActivityLogger.shared.log(.error, "Mic switch failed: \(error.localizedDescription)")
        }
    }

    func restorePreferredMicMode() async {
        let saved = MicMode(rawValue: AppSettings.shared.preferredMicMode) ?? .builtIn
        if saved != .builtIn {
            await switchMicMode(saved)
        }
    }

    // MARK: - Music Auto-Switch (BT mic ↔ built-in)

    private var musicSwitchTask: Task<Void, Never>?

    private func startMusicAutoSwitch() {
        musicSwitchTask?.cancel()
        musicSwitchTask = Task { [weak self] in
            let nowPlaying = TelemetryService.shared.nowPlayingManager
            var wasPlaying = nowPlaying.isPlaying
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                let isPlaying = nowPlaying.isPlaying
                guard isPlaying != wasPlaying else { continue }
                wasPlaying = isPlaying

                let savedMode = MicMode(rawValue: AppSettings.shared.preferredMicMode) ?? .builtIn
                guard savedMode == .bluetoothHFP else { continue }

                if isPlaying {
                    // Music started → temporarily switch to built-in (stereo)
                    let mgr = AudioSessionManager.shared
                    mgr.setDesiredMicMode(.builtIn)
                    try? mgr.configure()
                    let builtIn = mgr.availableInputs.first { $0.portType == .builtInMic }
                    try? mgr.setPreferredInput(builtIn)
                    self.engine?.restartEngine()
                    ActivityLogger.shared.log(.state, "Auto-switch: music → stereo + built-in mic")
                } else {
                    // Music stopped → restore BT mic
                    await self.switchMicMode(.bluetoothHFP)
                    ActivityLogger.shared.log(.state, "Auto-switch: music stopped → BT mic restored")
                }
            }
        }
    }

    private let maxStartRetries = 3
    private var retryTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?

    func start(modelContainer: ModelContainer) async {
        RecordingStateManager.shared.userStopIntent = false
        lastModelContainer = modelContainer
        for attempt in 1...maxStartRetries {
            do {
                if engine == nil {
                    engine = AudioRecordingEngine()
                    engine?.setModelContainer(modelContainer)
                }
                try await engine?.start()
                errorMessage = nil
                logger.info("Recording started")
                await restorePreferredMicMode()

                // Resume upload queue if not already running
                if !UploadManager.shared.isUploading {
                    let context = ModelContext(modelContainer)
                    UploadManager.shared.startProcessing(modelContext: context)
                }

                syncSharedState()
                startHealthMonitor(modelContainer: modelContainer)
                startMusicAutoSwitch()
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

    /// Backoff schedule (seconds). Permanent but sparse — no cap on attempts,
    /// just sparser cadence so we don't burn battery / iOS scheduling budget.
    /// Index 0..6, then stays at 1800 (30 min) forever.
    private static let retryBackoffSeconds: [Int] = [10, 30, 60, 120, 300, 900, 1800]

    private func backoffDelay(attempt: Int) -> Int {
        let i = min(attempt, Self.retryBackoffSeconds.count - 1)
        return Self.retryBackoffSeconds[i]
    }

    private func scheduleBackgroundRetry(modelContainer: ModelContainer) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            var attempt = 0
            var intLaneAttempt = 0   // long-backoff lane for !int (cannotInterruptOthers)
            while !Task.isCancelled {
                // Choose backoff: !int gets longer waits, normal failures get standard ladder
                let delaySec = intLaneAttempt > 0
                    ? self?.backoffDelay(attempt: intLaneAttempt + 1) ?? 60
                    : self?.backoffDelay(attempt: attempt) ?? 30
                try? await Task.sleep(for: .seconds(delaySec))
                guard let self, !Task.isCancelled else { return }
                guard self.engine?.state == .idle else { return } // recovered
                attempt += 1
                let lane = intLaneAttempt > 0 ? "intLane=\(intLaneAttempt)" : "normal"
                ActivityLogger.shared.log(.state, "Background retry #\(attempt) (delay=\(delaySec)s, \(lane))")
                self.engine?.stop()   // intentional: false — keepalive stays alive
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
                    self.startMusicAutoSwitch()
                    return
                } catch {
                    let desc = error.localizedDescription
                    let isIntConflict = AudioSessionManager.isCannotInterruptOthers(error)
                    if isIntConflict {
                        intLaneAttempt += 1
                        ActivityLogger.shared.log(.error, "Background retry #\(attempt) failed: !int (cannotInterruptOthers) — long backoff lane=\(intLaneAttempt)")
                    } else {
                        intLaneAttempt = 0   // exit lane on non-!int failure
                        ActivityLogger.shared.log(.error, "Background retry #\(attempt) failed: \(desc)")
                    }
                }
            }
        }
    }

    /// Foreground/route nudge — ask the engine to retry a blocked background
    /// activation now (no-ops unless the engine is actually blocked).
    func resumeIfActivationBlocked() {
        engine?.resumeWhenActivatable(reason: "foreground")
    }

    /// Upper-level health monitor — independent of engine's internal watchdog.
    /// Detects engine death that the watchdog couldn't recover from and recreates the engine entirely.
    /// Polls every 5s. Triggers full recreate when:
    ///   - engine instance is nil, or
    ///   - `engineNeedsRecreate` flag is set (installTap NSException → poisoned instance), or
    ///   - engine has been idle without user-stop (fallback for non-exception failures).
    private func startHealthMonitor(modelContainer: ModelContainer) {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }

                guard let engine = self.engine else {
                    ActivityLogger.shared.log(.error, "HealthMonitor: engine is nil — recreating")
                    await self.start(modelContainer: modelContainer)
                    return
                }

                if engine.engineNeedsRecreate && !engine.userStopped {
                    if !ConnectivityMonitor.shared.isAppActive,
                       let notBefore = engine.engineRecreateNotBefore,
                       Date() < notBefore {
                        continue
                    }
                    ActivityLogger.shared.log(.error, "HealthMonitor: engine poisoned (installTap NSException) — full recreate")
                    self.engine?.stop()
                    self.engine = nil
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
        RecordingStateManager.shared.userStopIntent = true
        musicSwitchTask?.cancel()
        musicSwitchTask = nil
        healthCheckTask?.cancel()
        healthCheckTask = nil
        retryTask?.cancel()
        retryTask = nil
        engine?.stop(intentional: true)
        AudioSessionManager.shared.deactivate()
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
