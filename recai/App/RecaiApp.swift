import SwiftUI
import SwiftData

@main
struct RecaiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

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
                .task {
                    // Auto-start upload queue on app launch
                    let context = ModelContext(sharedModelContainer)
                    UploadManager.shared.startProcessing(modelContext: context)

                    // Start connectivity monitoring
                    ConnectivityMonitor.shared.start()

                    // Reset RMS threshold if too high for distant speech pickup
                    if AppSettings.shared.rmsThreshold > 0.01 {
                        AppSettings.shared.rmsThreshold = 0.003
                    }

                    // Auto-configure telemetry server if not set
                    if AppSettings.shared.telemetryServerURL.isEmpty {
                        AppSettings.shared.telemetryServerURL = "http://telemetry.example.invalid:18789"
                    }
                    if !KeychainHelper.shared.hasToken {
                        try? KeychainHelper.shared.saveToken("REDACTED_TELEMETRY_TOKEN")
                    }

                    // Start telemetry (health + location)
                    TelemetryService.shared.start()
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
