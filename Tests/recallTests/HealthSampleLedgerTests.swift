import XCTest
@testable import recall

final class HealthSampleLedgerTests: XCTestCase {
    private func sample(_ uuid: String, value: Double = 70) -> RawHealthSample {
        RawHealthSample(uuid: uuid, type: "hr", start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2),
                        value: value, unit: "count/min", valueText: nil, source: "ring", sourceBundleId: "ring",
                        sourceVersion: nil, deviceModel: nil, durationSeconds: nil)
    }

    func testARewriteWithTheSameContentSendsNothing() {
        var ledger = HealthSampleLedger()
        XCTAssertEqual(ledger.news(items: [sample("a")], deleted: []).items.map(\.uuid), ["a"])
        let rewrite = ledger.news(items: [sample("b")], deleted: ["a"])
        XCTAssertTrue(rewrite.items.isEmpty)
        XCTAssertTrue(rewrite.deleted.isEmpty)
    }

    func testAChangedValueSendsTheNewSampleAndDeletesTheOld() {
        var ledger = HealthSampleLedger()
        _ = ledger.news(items: [sample("a")], deleted: [])
        let change = ledger.news(items: [sample("b", value: 71)], deleted: ["a"])
        XCTAssertEqual(change.items.map(\.uuid), ["b"])
        XCTAssertEqual(change.deleted, ["a"])
    }

    func testADeletionOfSomethingHubNeverGotIsNotSent() {
        var ledger = HealthSampleLedger()
        XCTAssertTrue(ledger.news(items: [], deleted: ["never-sent"]).deleted.isEmpty)
    }

    func testRemovingTheLastCopyDeletesTheUUIDHubHolds() {
        var ledger = HealthSampleLedger()
        _ = ledger.news(items: [sample("a")], deleted: [])
        _ = ledger.news(items: [sample("b")], deleted: ["a"])
        XCTAssertEqual(ledger.news(items: [], deleted: ["b"]).deleted, ["a"])
    }
}
