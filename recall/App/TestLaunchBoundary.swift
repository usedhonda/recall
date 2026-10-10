import Foundation

/// Hosted unit tests must not start live capture or delivery as a side effect
/// of loading the application. This has no effect on release app launches.
enum TestLaunchBoundary {
    static var isTesting: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
        #else
        return false
        #endif
    }
}
