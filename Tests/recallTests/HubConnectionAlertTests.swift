import XCTest
import SwiftUI
@testable import recall

final class HubConnectionAlertTests: XCTestCase {
    @MainActor
    func testConnectionBannerFitsNarrowDisplay() throws {
        let renderer = ImageRenderer(content:
            HubConnectionBanner(issue: .unreachable(URLError.timedOut.rawValue))
                .frame(width: 320)
                .background(RecallTheme.Colors.bg))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, 320)
        XCTAssertGreaterThan(image.size.height, 60)
        XCTAssertLessThan(image.size.height, 220)
        let attachment = XCTAttachment(image: image)
        attachment.name = "hub-connection-banner-320pt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOneNotificationAcrossLanesAndRelaunchUntilAnHTTPResponse() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var state = HubConnectionAlertState()
        state.failed(.unreachable(URLError.timedOut.rawValue), attemptStartedAt: start)
        XCTAssertFalse(state.claimNotification(networkAvailable: false), "ordinary offline is not a VPN alert")
        XCTAssertTrue(state.claimNotification(networkAvailable: true))
        state.failed(.unreachable(URLError.cannotFindHost.rawValue), attemptStartedAt: start.addingTimeInterval(1))
        XCTAssertFalse(state.claimNotification(networkAvailable: true), "another lane cannot repeat the alert")
        state = try JSONDecoder().decode(HubConnectionAlertState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(state.claimNotification(networkAvailable: true), "relaunch cannot repeat the alert")
        XCTAssertFalse(state.claimNotification(networkAvailable: false))
        XCTAssertFalse(state.claimNotification(networkAvailable: true), "Internet reconnection is not Hub recovery")

        let responseAt = start.addingTimeInterval(60)
        state.responded(status: 401, at: responseAt)
        XCTAssertEqual(state.issue, .rejected(401), "HTTP proves a route, not permission or delivery")
        XCTAssertFalse(state.claimNotification(networkAvailable: true))
        state.failed(.unreachable(URLError.timedOut.rawValue), attemptStartedAt: start.addingTimeInterval(30))
        XCTAssertEqual(state.issue, .rejected(401), "an old in-flight timeout cannot reopen a recovered outage")
        state.failed(.unreachable(URLError.timedOut.rawValue), attemptStartedAt: responseAt.addingTimeInterval(1),
                     at: responseAt.addingTimeInterval(2))
        XCTAssertEqual(state.issue, .retrying(URLError.timedOut.rawValue))
        XCTAssertTrue(state.issue?.isRetrying == true)
        XCTAssertFalse(state.claimNotification(networkAvailable: true), "a recent real response prevents transient alert spam")
        state.failed(.unreachable(URLError.timedOut.rawValue), attemptStartedAt: responseAt.addingTimeInterval(61),
                     at: responseAt.addingTimeInterval(62))
        XCTAssertTrue(state.claimNotification(networkAvailable: true), "a genuinely new outage gets one alert")
        XCTAssertFalse(state.claimNotification(networkAvailable: true))
    }

    func testTLSReceiptAndHTTPFailuresDoNotClaimThatTailscaleIsOff() {
        let now = Date()
        for issue in [HubConnectionIssue.secureConnection, .receipt, .configuration,
                      .networkOther(URLError.dataNotAllowed.rawValue), .rejected(403), .rejected(503)] {
            var state = HubConnectionAlertState()
            state.failed(issue, attemptStartedAt: now)
            XCTAssertFalse(state.claimNotification(networkAvailable: true))
            XCTAssertFalse(issue.detail.contains("Tailscale"))
        }
        XCTAssertEqual(HubConnectionIssue.networkFailure(URLError.secureConnectionFailed.rawValue), .secureConnection)
        XCTAssertNil(HubConnectionIssue.networkFailure(URLError.cancelled.rawValue))
        let timeout = HubConnectionIssue.networkFailure(URLError.timedOut.rawValue)
        XCTAssertTrue(timeout?.detail.contains("Check that Tailscale is connected") == true)
        XCTAssertFalse(timeout?.detail.contains("Tailscale is off") == true)
    }
}
