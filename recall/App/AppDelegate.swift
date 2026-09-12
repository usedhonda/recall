import UIKit
import OSLog

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "com.recall", category: "AppDelegate")
    /// Held for the process lifetime: the Control Center toggle used to be observed
    /// from a SwiftUI `.task`, which dies with the scene and swallowed toggles.
    private var recordingToggleToken: DarwinNotificationToken?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // First, before any other line lands: how long was nobody running?
        ActivityLogger.shared.noteProcessStart()
        LaunchContext.recordLaunch(applicationState: application.applicationState)
        ConnectivityMonitor.shared.start()

        // Set up HealthKit background delivery — must be in didFinishLaunchingWithOptions
        // so observer queries are ready before iOS delivers background updates
        TelemetryService.shared.healthManager.setupBackgroundDelivery()

        recordingToggleToken = RecordingStateManager.shared.observeDarwinNotification {
            Task { @MainActor in
                await RecordingViewModel.shared.handleExternalToggle()
            }
        }

        logger.info("App launched, connectivity monitor + health background delivery started")
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("Background URL session event: \(identifier)")
        if identifier == "com.recall.telemetry-upload" {
            TelemetryUploader.shared.handleBackgroundSession(completionHandler: completionHandler)
        } else {
            BackgroundUploadService.shared.setBackgroundCompletionHandler(completionHandler)
        }
    }
}
