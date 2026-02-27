import UIKit
import OSLog

final class AppDelegate: NSObject, UIApplicationDelegate {
    private let logger = Logger(subsystem: "com.recai", category: "AppDelegate")

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ConnectivityMonitor.shared.start()
        logger.info("App launched, connectivity monitor started")
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        logger.info("Background URL session event: \(identifier)")
        if identifier == "com.recai.telemetry-upload" {
            TelemetryUploader.shared.handleBackgroundSession(completionHandler: completionHandler)
        } else {
            BackgroundUploadService.shared.setBackgroundCompletionHandler(completionHandler)
        }
    }
}
