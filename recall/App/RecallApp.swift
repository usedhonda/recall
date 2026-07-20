import SwiftUI
import SwiftData

@main
struct RecallApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var recordingViewModel = RecordingViewModel()
    @State private var normalStartupStarted = false
    @State private var independentStreamsStarted = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([AudioChunk.self, MediaChunk.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recordingViewModel)
                .task {
                    if !LaunchContext.launchedInBackground {
                        LaunchContext.markUserForeground()
                    }
                    guard !LaunchContext.shouldStaySilent else {
                        // Recording auto-start is suppressed while silent, but the
                        // independent streams (location, health, upload, media/glasses)
                        // follow only their own toggles and must still start.
                        QuietLaunchHandler.teardownForSilentLaunch()
                        await startIndependentStreams()
                        return
                    }
                    await runNormalStartup()
                }
                .task(id: "darwinObserver") {
                    // Observe Darwin notifications from Control Center widget
                    await observeExternalToggle()
                }
                .onChange(of: scenePhase) { _, phase in
                    // Data saver gate: foreground sends, background stays silent.
                    ConnectivityMonitor.shared.isAppActive = (phase == .active)
                    guard phase == .active else { return }
                    LaunchContext.markUserForeground()
                    RecordingStateManager.shared.userStopIntent = false
                    // Foreground is the moment iOS is most likely to grant setActive —
                    // nudge the engine to retry any background-blocked (-50) activation.
                    recordingViewModel.resumeIfActivationBlocked()
                    Task {
                        await runNormalStartup()
                        // Drain location samples queued while backgrounded.
                        await TelemetryUploader.shared.triggerUpload()
                    }
                }
        }
        .modelContainer(sharedModelContainer)
    }

    @MainActor
    private func runNormalStartup() async {
        // Reaching normal startup means we are foregrounded — mark active so the
        // first telemetry send isn't dropped by the data saver gate before the
        // scenePhase observer fires.
        ConnectivityMonitor.shared.isAppActive = true
        guard !normalStartupStarted else { return }
        normalStartupStarted = true
        RecordingStateManager.shared.userStopIntent = false

        // Auto-start recording on launch (recording lane).
        RecordingStateManager.shared.isRecording = true
        await recordingViewModel.start(modelContainer: sharedModelContainer)

        // Independent streams (location, health, upload, media/glasses) run
        // regardless of the recording lane.
        await startIndependentStreams()
    }

    /// Start the independent data streams (upload queue, connectivity, server
    /// health, telemetry, glasses handoff). These follow only their own toggles
    /// and run on both normal and silent launches — never gated by recording state.
    @MainActor
    private func startIndependentStreams() async {
        guard !independentStreamsStarted else { return }
        independentStreamsStarted = true

        // Auto-start upload queue on app launch
        let context = ModelContext(sharedModelContainer)
        UploadManager.shared.reconcileStuckUploads(modelContext: context)
        UploadManager.shared.retryFailed(modelContext: context)
        UploadManager.shared.startProcessing(modelContext: context)

        // Start connectivity monitoring
        ConnectivityMonitor.shared.start()

        // Start server health monitoring (probes upload server reachability)
        ServerHealthMonitor.shared.start()

        // Reset RMS threshold if too high for pocket/distant speech pickup
        if AppSettings.shared.rmsThreshold > 0.005 {
            AppSettings.shared.rmsThreshold = 0.002
        }

        // Reset min chunk duration to 2s (was 5s, too aggressive for short speech)
        if AppSettings.shared.minChunkDurationSeconds > 2.0 {
            AppSettings.shared.minChunkDurationSeconds = 2.0
        }

        // Force telemetry interval to 15s for max frequency
        if AppSettings.shared.telemetrySendInterval > 15 {
            AppSettings.shared.telemetrySendInterval = 15
        }

        // Ensure all telemetry streams are enabled (critical for always-on operation)
        if !AppSettings.shared.locationEnabled {
            AppSettings.shared.locationEnabled = true
        }
        if !AppSettings.shared.locationBackgroundEnabled {
            AppSettings.shared.locationBackgroundEnabled = true
        }
        if !AppSettings.shared.healthEnabled {
            AppSettings.shared.healthEnabled = true
        }

        // Start telemetry (health + location)
        TelemetryService.shared.start()

        // Photo-library scan (PhotoScanCoordinator) retired: glasses photos now arrive
        // via the App Group handoff below (~0.3s) instead of the ~1h Photos-app sync
        // lag. The library scan is intentionally no longer started.

        // Glasses photo handoff from vibeterm (App Group drop folder). No permission
        // prerequisite, so started unconditionally. Dormant until vibeterm drops files.
        TelemetryService.shared.glassesHandoffReceiver.setModelContainer(sharedModelContainer)
        TelemetryService.shared.glassesHandoffReceiver.start()
        MediaUploadManager.shared.startProcessing(modelContainer: sharedModelContainer)

        // Report per-channel on/off intent so the server can tell "user gated a
        // stream" from "device dead" (runs on both normal and silent launches).
        ChannelStatusReporter.shared.start()
    }

    @MainActor
    private func observeExternalToggle() async {
        // Keep observation alive for the lifetime of the app
        let stream = AsyncStream<Void> { continuation in
            let token = RecordingStateManager.shared.observeDarwinNotification {
                continuation.yield()
            }
            continuation.onTermination = { _ in
                // prevent token from being deallocated
                _ = token
            }
        }

        for await _ in stream {
            await recordingViewModel.handleExternalToggle(
                modelContainer: sharedModelContainer
            )
        }
    }
}
