import UIKit
import OSLog

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "com.recall", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ConnectivityMonitor.shared.start()

        // Set up HealthKit background delivery — must be in didFinishLaunchingWithOptions
        // so observer queries are ready before iOS delivers background updates
        TelemetryService.shared.healthManager.setupBackgroundDelivery()

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
