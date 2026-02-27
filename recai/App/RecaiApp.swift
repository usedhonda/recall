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
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
