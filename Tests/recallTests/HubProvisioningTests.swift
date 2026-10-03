import XCTest
@testable import recall

final class HubProvisioningTests: XCTestCase {
    private func config(source: String = "recall", endpoint: String = "https://hub.example.invalid",
                        token: String = "fixture-token", deviceID: String = "fixture-device",
                        enabled: Set<String> = ["gps-delivery"], disabled: Set<String> = []) -> HubDeviceConfiguration {
        HubDeviceConfiguration(schemaVersion: 1, source: source, endpoint: URL(string: endpoint)!,
                               bearerToken: token, deviceID: deviceID, enabledRoutes: enabled,
                               legacyDisabledRoutes: disabled)
    }

    func testPrivateConfigurationKeepsSourceAndDeviceBound() throws {
        XCTAssertNoThrow(try config().validated(deviceID: "fixture-device"))
        XCTAssertThrowsError(try config(source: "other").validated(deviceID: "fixture-device"))
        XCTAssertThrowsError(try config().validated(deviceID: "another-device"))
        XCTAssertThrowsError(try config(endpoint: "http://hub.example.invalid").validated(deviceID: "fixture-device"))
        XCTAssertThrowsError(try config(token: "token\ninvalid").validated(deviceID: "fixture-device"))
    }

    func testLegacyCutoverMustNameAnEnabledKnownRoute() {
        XCTAssertThrowsError(try config(enabled: ["unknown"]).validated(deviceID: "fixture-device"))
        XCTAssertThrowsError(try config(disabled: ["audio-original"]).validated(deviceID: "fixture-device"))
        XCTAssertNoThrow(try config(disabled: ["gps-delivery"]).validated(deviceID: "fixture-device"))
    }
}
