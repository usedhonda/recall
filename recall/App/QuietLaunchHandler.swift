import Foundation

@MainActor
enum QuietLaunchHandler {
    static func teardownForSilentLaunch() {
        ActivityLogger.shared.log(.state, "Silent launch: tearing down location, health, and upload monitors")
        TelemetryService.shared.locationManager.stopUpdates()
        TelemetryService.shared.healthManager.disableBackgroundDelivery()
        TelemetryService.shared.healthManager.stopTimer()
        UploadManager.shared.stopProcessing()
        MediaUploadManager.shared.stopProcessing()
        ServerHealthMonitor.shared.stop()
    }
}
