import Foundation

@MainActor
enum QuietLaunchHandler {
    static func teardownForSilentLaunch() {
        ActivityLogger.shared.log(.state, "Silent launch: recording auto-start suppressed; independent streams unaffected")
    }
}
