import XCTest
@testable import recall

final class OutboxAlertTests: XCTestCase {
    func testSteadyStateStaysSilentButAFillingLaneAnUnreadableOutboxAndRecoveryAreEdges() {
        let normal = OutboxAlert.classify(snapshotAvailable: true, alertLanes: [])
        XCTAssertEqual(normal, "ok")
        XCTAssertFalse(OutboxAlert.isEdge(current: normal, lastSent: nil), "all-active steady state sends nothing")
        XCTAssertFalse(OutboxAlert.isEdge(current: normal, lastSent: "ok"))

        let high = OutboxAlert.classify(snapshotAvailable: true, alertLanes: ["metadata-status", "metadata-gps"])
        XCTAssertEqual(high, "high:metadata-status,metadata-gps")
        XCTAssertTrue(OutboxAlert.isEdge(current: high, lastSent: "ok"), "crossing 80% must reach the server")
        XCTAssertTrue(OutboxAlert.isEdge(current: high, lastSent: nil))
        XCTAssertFalse(OutboxAlert.isEdge(current: high, lastSent: high), "no resend until it changes")
        XCTAssertTrue(OutboxAlert.needsLevel(current: high), "a non-normal state repeats hourly")

        let unknown = OutboxAlert.classify(snapshotAvailable: false, alertLanes: [])
        XCTAssertEqual(unknown, "unknown", "an unreadable outbox is never reported as healthy")
        XCTAssertTrue(OutboxAlert.isEdge(current: unknown, lastSent: nil))
        XCTAssertTrue(OutboxAlert.needsLevel(current: unknown))

        XCTAssertTrue(OutboxAlert.isEdge(current: normal, lastSent: high), "going back to normal is reported once")
        XCTAssertFalse(OutboxAlert.needsLevel(current: normal))
    }

    func testAGapWriteThatFailedIsRetriedAndOnlyAWrittenOneMovesTheState() async {
        var high: [String: Bool] = [:]
        var attempts: [String] = []
        var failNext = true
        let tracker = UsageGapTracker(
            isHigh: { high[$0] ?? false },
            setHigh: { high[$0] = $1 },
            record: { lane, reason in
                attempts.append("\(lane):\(reason)")
                if failNext { failNext = false; return false }
                return true
            })

        await tracker.apply(lane: "metadata-gps", ratio: 0.9)
        XCTAssertEqual(high["metadata-gps"] ?? false, false, "a failed write must not be treated as recorded")
        await tracker.apply(lane: "metadata-gps", ratio: 0.9)
        XCTAssertEqual(high["metadata-gps"], true, "retried at the next evaluation and recorded")
        await tracker.apply(lane: "metadata-gps", ratio: 0.95)
        XCTAssertEqual(attempts, ["metadata-gps:usage_ge_80", "metadata-gps:usage_ge_80"], "no repeat once recorded")

        await tracker.apply(lane: "metadata-gps", ratio: 0.6)
        XCTAssertEqual(high["metadata-gps"], false)
        XCTAssertEqual(attempts.last, "metadata-gps:usage_recovered")
    }

    func testNormalLevelIsDueFirstThenHourly() {
        let now = Date()
        XCTAssertTrue(OutboxAlert.levelDue(lastAcknowledgedAt: nil, now: now, interval: 3600), "first tick sends")
        XCTAssertFalse(OutboxAlert.levelDue(lastAcknowledgedAt: now.addingTimeInterval(-3599), now: now, interval: 3600))
        XCTAssertTrue(OutboxAlert.levelDue(lastAcknowledgedAt: now.addingTimeInterval(-3600), now: now, interval: 3600))
        XCTAssertTrue(OutboxAlert.levelDue(lastAcknowledgedAt: now.addingTimeInterval(60), now: now, interval: 3600),
                      "a clock set backwards must not silence the level")
    }
}
