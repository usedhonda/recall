import SwiftUI
import SwiftData

@main
struct RecallApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var recordingViewModel = RecordingViewModel()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([AudioChunk.self])
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
                    // Auto-start recording on launch
                    RecordingStateManager.shared.isRecording = true
                    await recordingViewModel.start(modelContainer: sharedModelContainer)

                    // Auto-start upload queue on app launch
                    let context = ModelContext(sharedModelContainer)
                    UploadManager.shared.reconcileStuckUploads(modelContext: context)
                    UploadManager.shared.startProcessing(modelContext: context)

                    // Start connectivity monitoring
                    ConnectivityMonitor.shared.start()

                    // Reset RMS threshold if too high for pocket/distant speech pickup
                    if AppSettings.shared.rmsThreshold > 0.005 {
                        AppSettings.shared.rmsThreshold = 0.002
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
                }
                .task(id: "darwinObserver") {
                    // Observe Darwin notifications from Control Center widget
                    await observeExternalToggle()
                }
        }
        .modelContainer(sharedModelContainer)
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
