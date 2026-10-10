import XCTest
@testable import recall

final class TelemetryAcknowledgmentTests: XCTestCase {
    @MainActor
    func testForegroundHubPendingBindingAndLateReceiptAreIdempotent() async throws {
        let ledgerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recall-health-binding-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ledgerURL) }
        let ledger = TelemetryBatchLedger(url: ledgerURL)
        let payload = HealthPayload(collectedAt: Date(), records: [], sleep: nil, workouts: nil)
        let deliveryID = payload.deliveryID.uuidString
        let result = await TelemetryService.shared.registerHubHealthPending(
            payload, fingerprint: "original-fingerprint", externalID: "hub-external-id", ledger: ledger
        )
        XCTAssertTrue(result.isSending)
        XCTAssertEqual(payload.deliveryID.uuidString, deliveryID)
        let pending = await ledger.pendingHealth(deliveryID: deliveryID)
        XCTAssertEqual(pending?.healthHubExternalID, "hub-external-id")
        XCTAssertEqual(pending?.healthFingerprint, "original-fingerprint")

        let originalHandler = TelemetryUploader.shared.healthAcknowledgmentHandler
        defer { TelemetryUploader.shared.healthAcknowledgmentHandler = originalHandler }
        let manager = HealthKitManager()
        manager.resetRuntimeCounters()
        XCTAssertEqual(manager.totalSuccessfulSends, 0)
        XCTAssertEqual(manager.totalSendErrors, 0)
        // Relaunch has no live pending map. The validated receipt must use the
        // durable original binding, not a subsequent Health aggregate's UUID.
        let reopened = TelemetryBatchLedger(url: ledgerURL)
        let accepted = try await reopened.acknowledgeHubHealth(externalID: "hub-external-id") { id, fingerprint in
            XCTAssertEqual(id, deliveryID)
            return manager.acknowledgeBackgroundHealth(deliveryID: id, fingerprint: fingerprint, source: .hub)
        }
        XCTAssertTrue(accepted)
        let duplicate = try await reopened.acknowledgeHubHealth(externalID: "hub-external-id") { _, _ in
            XCTFail("duplicate receipt must not invoke the consumer again")
            return true
        }
        XCTAssertFalse(duplicate)
        XCTAssertFalse(manager.acknowledgeBackgroundHealth(deliveryID: deliveryID, fingerprint: "wrong", source: .hub))
        XCTAssertTrue(manager.acknowledgeBackgroundHealth(deliveryID: deliveryID, fingerprint: "original-fingerprint", source: .hub))
        XCTAssertEqual(manager.totalSuccessfulSends, 1)
    }

    func testHealthRequiresExplicitAcknowledgement() throws {
        let data = Data(#"{"received":0,"healthReceived":true,"nextMinIntervalSec":60}"#.utf8)
        let response = try TelemetryAcknowledgment.validate(data: data, statusCode: 200, requiresHealth: true)
        XCTAssertEqual(response.healthReceived, true)
    }

    func testMissingOrFalseHealthAcknowledgementIsRejected() {
        for body in [
            #"{"received":0,"nextMinIntervalSec":60}"#,
            #"{"received":0,"healthReceived":false}"#
        ] {
            XCTAssertThrowsError(try TelemetryAcknowledgment.validate(
                data: Data(body.utf8), statusCode: 204, requiresHealth: true
            ))
        }
    }

    func testLocationMayOmitHealthAcknowledgement() throws {
        let data = Data(#"{"received":1,"nextMinIntervalSec":60}"#.utf8)
        let response = try TelemetryAcknowledgment.validate(data: data, statusCode: 200, requiresHealth: false)
        XCTAssertNil(response.healthReceived)
    }

    func testNonSuccessStatusIsRejectedBeforeDecode() {
        XCTAssertThrowsError(try TelemetryAcknowledgment.validate(
            data: Data(#"{"received":0,"healthReceived":true}"#.utf8),
            statusCode: 500,
            requiresHealth: true
        ))
    }

}
