import UIKit

@MainActor
enum LaunchContext {
    static var launchedInBackground = false
    static var userDidForeground = false
    /// True for a process started by a deployment that asked to keep a stored stop (see
    /// `isBackgroundLaunch`). It lasts for that process only; the next ordinary launch is
    /// governed by the usual rules.
    static var deploymentPreservesOff = false

    enum ForegroundAction { case normalStartup, independentStreamsOnly }

    /// What the scene-becomes-active callback may do. A deployment-preserved stop must not be
    /// cleared by an activation that the deployment itself may have caused.
    nonisolated static func foregroundAction(deploymentPreservesOff: Bool) -> ForegroundAction {
        deploymentPreservesOff ? .independentStreamsOnly : .normalStartup
    }

    /// Set only by a deployment that must not turn recording on (`devicectl ... launch
    /// --environment-variables`). A normal user launch never carries it.
    static let preserveOffEnvironmentKey = "RECALL_PRESERVE_OFF"

    /// A launch counts as background when iOS says so, or when a deployment asked to keep a
    /// recorded user stop and one is stored. Pure so the rule can be tested.
    nonisolated static func isBackgroundLaunch(
        applicationState: UIApplication.State, environment: [String: String], userStopIntent: Bool
    ) -> Bool {
        applicationState == .background
            || (environment[preserveOffEnvironmentKey] == "1" && userStopIntent)
    }

    static func recordLaunch(applicationState: UIApplication.State) {
        let environment = ProcessInfo.processInfo.environment
        let storedStop = RecordingStateManager.shared.userStopIntent
        launchedInBackground = isBackgroundLaunch(
            applicationState: applicationState, environment: environment, userStopIntent: storedStop)
        deploymentPreservesOff = environment[preserveOffEnvironmentKey] == "1" && storedStop
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
