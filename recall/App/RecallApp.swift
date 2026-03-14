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
                    // Keep app alive in background for telemetry (independent of recording)
                    BackgroundKeepAlive.shared.start()

                    // Auto-start recording on launch
                    RecordingStateManager.shared.isRecording = true
                    await recordingViewModel.start(modelContainer: sharedModelContainer)

                    // Migrate Tailscale IP-based URLs to hostname (ATS requires .ts.net domain)
                    Self.migrateTailscaleURLs()

                    // Auto-start upload queue on app launch
                    let context = ModelContext(sharedModelContainer)
                    UploadManager.shared.reconcileStuckUploads(modelContext: context)
                    UploadManager.shared.retryFailed(modelContext: context)
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

    /// Migrate any Tailscale IP-based URLs to .ts.net hostname.
    /// ATS blocks plain HTTP to IP addresses, but allows .ts.net via NSExceptionDomains.
    private static func migrateTailscaleURLs() {
        let settings = AppSettings.shared
        let urlValues = [
            (settings.uploadServerURL, "uploadServerURL"),
            (settings.telemetryServerURL, "telemetryServerURL"),
        ]

        // Find the .ts.net hostname from telemetryServerURL (which is known-good)
        guard let tsURL = URL(string: settings.telemetryServerURL),
              let tsHost = tsURL.host, tsHost.hasSuffix(".ts.net") else {
            return // No .ts.net reference to migrate to
        }

        for (value, key) in urlValues {
            guard !value.isEmpty, !value.contains("ts.net") else { continue }
            guard let url = URL(string: value),
                  let host = url.host, host.starts(with: "100.") else { continue }
            let port = url.port.map { ":\($0)" } ?? ""
            let path = url.path
            let scheme = url.scheme ?? "http"
            let migrated = "\(scheme)://\(tsHost)\(port)\(path)"
            UserDefaults.standard.set(migrated, forKey: key)
            ActivityLogger.shared.log(.network, "Migrated URL: \(value) -> \(migrated)")
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
