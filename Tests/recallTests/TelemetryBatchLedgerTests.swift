import XCTest
@testable import recall

final class TelemetryBatchLedgerTests: XCTestCase {
    func testSchedulingPersistsOwnershipUntilVerifiedDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("batches.json")
        let body = root.appendingPathComponent("request.json")
        try Data("{}".utf8).write(to: body)
        let id = UUID()
        let first = TelemetryBatchLedger(url: path)
        let row = try await first.create(sampleIDs: [id], healthIncluded: false, requestFile: body)
        try await first.setTaskDescription(row.id.uuidString, for: row.id)
        let reopened = TelemetryBatchLedger(url: path)
        let pendingValue = await reopened.pendingBatch(sampleIDs: [id], healthIncluded: false)
        let pending = try XCTUnwrap(pendingValue)
        XCTAssertEqual(pending.id, row.id)
        XCTAssertEqual(pending.state, .pending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path))
        _ = try await reopened.markDelivered(row.id)
        let remaining = await reopened.pending()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMissingTaskClearsIdentityButRetainsSameBatchAndBody() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("batches.json")
        let body = root.appendingPathComponent("request.json")
        try Data("frozen".utf8).write(to: body)
        let id = UUID()
        let ledger = TelemetryBatchLedger(url: path)
        let row = try await ledger.create(sampleIDs: [id], healthIncluded: true, requestFile: body)
        try await ledger.setTaskDescription("task", for: row.id)
        try await ledger.clearTaskDescription(row.id)
        let retryValue = await ledger.pendingBatch(sampleIDs: [id], healthIncluded: true)
        let retry = try XCTUnwrap(retryValue)
        XCTAssertEqual(retry.id, row.id)
        XCTAssertNil(retry.taskDescription)
        XCTAssertEqual(try Data(contentsOf: body), Data("frozen".utf8))
    }

    func testCallbackReducerAcceptsDuplicateIDsAndRejectsPartialBatch() {
        let first = UUID(), second = UUID()
        let duplicate = TelemetryResponse(received: 0, nextMinIntervalSec: nil,
                                          acknowledgedIDs: [first.uuidString, second.uuidString], healthReceived: false)
        XCTAssertTrue(TelemetryUploader.accepted(duplicate, sampleIDs: [first, second]))
        let partial = TelemetryResponse(received: 1, nextMinIntervalSec: nil,
                                        acknowledgedIDs: [first.uuidString], healthReceived: false)
        XCTAssertFalse(TelemetryUploader.accepted(partial, sampleIDs: [first, second]))
    }

    func testMixedGPSHealthRetainsFrozenBodyUntilHealthACK() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("batches.json"), body = root.appendingPathComponent("body")
        try Data("frozen".utf8).write(to: body)
        let ledger = TelemetryBatchLedger(url: path), sample = UUID()
        let row = try await ledger.create(sampleIDs: [sample], healthIncluded: true, healthDeliveryID: UUID().uuidString, requestFile: body)
        let partialValue = try await ledger.recordOutcome(row.id, location: true, health: false)
        let partial = try XCTUnwrap(partialValue)
        XCTAssertEqual(partial.state, .pending); XCTAssertTrue(partial.locationDelivered); XCTAssertFalse(partial.healthDelivered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: body.path))
        let completeValue = try await ledger.recordOutcome(row.id, location: true, health: true)
        let complete = try XCTUnwrap(completeValue)
        XCTAssertEqual(complete.state, .delivered)
        XCTAssertFalse(FileManager.default.fileExists(atPath: body.path))
    }
    func testBackgroundCompletionWaitsForPersistenceIncludingFailure() {
        let state = TelemetryCallbackState()
        state.append(Data("first".utf8), taskID: 1)
        state.append(Data("second".utf8), taskID: 1)
        XCTAssertEqual(state.beginCompletion(1), Data("firstsecond".utf8))
        state.finishEvents()
        XCTAssertFalse(state.consumeFinished())
        state.endCompletion()
        XCTAssertTrue(state.consumeFinished())
        XCTAssertFalse(state.consumeFinished())
    }

    func testUnreadableLedgerDoesNotOverwritePriorOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("batches.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: path)
        let ledger = TelemetryBatchLedger(url: path)
        do {
            _ = try await ledger.create(sampleIDs: [UUID()], healthIncluded: false,
                requestFile: root.appendingPathComponent("request.json"))
            XCTFail("corrupt ledger must refuse admission")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
    }

    @MainActor
    func testHubOnlyHealthPendingReloadsAndCompletesWithoutRequestFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("batches.json")
        let ledger = TelemetryBatchLedger(url: path)
        let deliveryID = UUID().uuidString
        try await ledger.recordHubHealthPending(deliveryID: deliveryID, fingerprint: "fp", externalID: "hub-id")
        let reopened = TelemetryBatchLedger(url: path)
        let pendingValue = await reopened.pendingHealth(deliveryID: deliveryID)
        let pending = try XCTUnwrap(pendingValue)
        do { _ = try await reopened.ensureRequestFile(for: pending); XCTFail("Hub-only row has no request file") } catch {}
        var notifications = 0
        let notify: @MainActor (String, String) -> Bool = { id, fingerprint in
            XCTAssertEqual(id, deliveryID)
            XCTAssertEqual(fingerprint, "fp")
            notifications += 1
            return true
        }
        let wrong = try await reopened.acknowledgeHubHealth(externalID: "other-hub-id", notify: notify)
        XCTAssertFalse(wrong)
        XCTAssertEqual(notifications, 0)
        let unavailable = try await reopened.acknowledgeHubHealth(externalID: "hub-id", notify: { _, _ in false })
        XCTAssertFalse(unavailable)
        let correct = try await reopened.acknowledgeHubHealth(externalID: "hub-id", notify: notify)
        XCTAssertTrue(correct)
        let duplicate = try await reopened.acknowledgeHubHealth(externalID: "hub-id", notify: notify)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(notifications, 1)
        let completedValue = await reopened.batch(id: pending.id)
        let completed = try XCTUnwrap(completedValue)
        XCTAssertEqual(completed.state, .delivered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testMixedBatchRouteGateRetainsWhenContainedHealthLegacyDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = TelemetryBatchLedger(url: root.appendingPathComponent("batches.json"))
        let file = root.appendingPathComponent("body")
        try Data("frozen".utf8).write(to: file)
        let row = try await ledger.create(sampleIDs: [UUID()], healthIncluded: true, nowPlayingIncluded: true, requestFile: file)
        XCTAssertFalse(TelemetryUploader.legacyRoutesAllowed(row, disabled: [HubRecallRoute.healthSnapshot.rawValue]))
        XCTAssertFalse(TelemetryUploader.legacyRoutesAllowed(row, disabled: [HubRecallRoute.nowPlaying.rawValue]))
        XCTAssertFalse(TelemetryUploader.legacyRoutesAllowed(row, disabled: [HubRecallRoute.gpsDelivery.rawValue]))
        XCTAssertTrue(TelemetryUploader.legacyRoutesAllowed(row, disabled: []))
        let retained = await ledger.batch(id: row.id)
        XCTAssertEqual(retained?.state, .pending)
        XCTAssertEqual(try Data(contentsOf: file), Data("frozen".utf8))
        let healthOnly = try await ledger.create(sampleIDs: [], healthIncluded: true, nowPlayingIncluded: true, requestFile: file)
        XCTAssertFalse(TelemetryUploader.legacyRoutesAllowed(healthOnly, disabled: [HubRecallRoute.nowPlaying.rawValue]))
        let path = root.appendingPathComponent("batches.json")
        // Codable dictionaries with UUID keys encode alternating key/value entries.
        var oldRows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [Any])
        for index in stride(from: 1, to: oldRows.count, by: 2) {
            var row = try XCTUnwrap(oldRows[index] as? [String: Any])
            row.removeValue(forKey: "nowPlayingIncluded")
            row.removeValue(forKey: "routeMetadataKnown")
            oldRows[index] = row
        }
        try JSONSerialization.data(withJSONObject: oldRows).write(to: path)
        let oldLedger = TelemetryBatchLedger(url: path)
        let oldValue = await oldLedger.batch(id: row.id)
        let old = try XCTUnwrap(oldValue)
        XCTAssertFalse(old.routeMetadataKnown)
        XCTAssertTrue(TelemetryUploader.legacyRoutesAllowed(old, disabled: []))
        XCTAssertFalse(TelemetryUploader.legacyRoutesAllowed(old, disabled: [HubRecallRoute.nowPlaying.rawValue]))
        try await oldLedger.clearTaskDescription(row.id)
        let reloaded = TelemetryBatchLedger(url: path)
        let roundTrip = await reloaded.batch(id: row.id)
        XCTAssertEqual(roundTrip?.routeMetadataKnown, false)
    }

}
