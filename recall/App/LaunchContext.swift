import UIKit

@MainActor
enum LaunchContext {
    static var launchedInBackground = false
    static var userDidForeground = false

    static func recordLaunch(applicationState: UIApplication.State) {
        launchedInBackground = applicationState == .background
        ActivityLogger.shared.log(
            .state,
            "Launch context: background=\(launchedInBackground) userStopIntent=\(RecordingStateManager.shared.userStopIntent)"
        )
    }

    static func markUserForeground() {
        guard !userDidForeground else { return }
        userDidForeground = true
        ActivityLogger.shared.log(.state, "Launch context: user foregrounded")
    }

    static var shouldStaySilent: Bool {
        !userDidForeground && (launchedInBackground || RecordingStateManager.shared.userStopIntent)
    }
}
