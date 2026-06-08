import SwiftUI
import SwiftData

@main
struct RecallApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var recordingViewModel = RecordingViewModel()
    @State private var normalStartupStarted = false

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
                        QuietLaunchHandler.teardownForSilentLaunch()
                        return
                    }
                    await runNormalStartup()
                }
                .task(id: "darwinObserver") {
                    // Observe Darwin notifications from Control Center widget
                    await observeExternalToggle()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    LaunchContext.markUserForeground()
                    RecordingStateManager.shared.userStopIntent = false
                    Task { await runNormalStartup() }
                }
        }
        .modelContainer(sharedModelContainer)
    }

    @MainActor
    private func runNormalStartup() async {
        guard !normalStartupStarted else { return }
        normalStartupStarted = true
        RecordingStateManager.shared.userStopIntent = false

        // Auto-start recording on launch
        RecordingStateManager.shared.isRecording = true
        await recordingViewModel.start(modelContainer: sharedModelContainer)

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

        // Auto-start Ray-Ban Meta photo import if enabled
        ActivityLogger.shared.log(.telemetry, "[photo] startup gate: enabled=\(AppSettings.shared.glassesAutoImportEnabled)")
        if AppSettings.shared.glassesAutoImportEnabled {
            let authorizer = TelemetryService.shared.photoLibraryAuthorizer
            authorizer.refresh()
            ActivityLogger.shared.log(.telemetry, "[photo] auth status (initial): \(PhotoLibraryAuthorizer.statusName(authorizer.status))")
            if !authorizer.canRead {
                _ = await authorizer.requestReadWrite()
                ActivityLogger.shared.log(.telemetry, "[photo] auth status (after request): \(PhotoLibraryAuthorizer.statusName(authorizer.status))")
            }
            if authorizer.canRead {
                TelemetryService.shared.photoScanCoordinator.setModelContainer(sharedModelContainer)
                TelemetryService.shared.photoScanCoordinator.start()
                MediaUploadManager.shared.startProcessing(modelContainer: sharedModelContainer)
            } else {
                ActivityLogger.shared.log(.error, "[photo] startup blocked — cannot read library")
            }
        }
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
