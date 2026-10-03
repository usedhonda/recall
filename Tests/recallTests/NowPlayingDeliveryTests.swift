import XCTest
@testable import recall

final class NowPlayingDeliveryTests: XCTestCase {
    func testLegacyProjectionPreservesFrozenSnapshotForPrimaryAndFallback() throws {
        let snapshot = NowPlayingSnapshot(
            title: "Fixture Track",
            artist: "Fixture Artist",
            album: "Fixture Album",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let primary = NowPlayingTelemetryProjection.legacySnapshot(
            snapshot, streamEnabled: true, legacyAllowed: true
        )
        let fallback = NowPlayingTelemetryProjection.legacySnapshot(
            snapshot, streamEnabled: true, legacyAllowed: true
        )

        XCTAssertEqual(primary?.deliveryID, snapshot.deliveryID)
        XCTAssertEqual(fallback?.deliveryID, snapshot.deliveryID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try XCTUnwrap(primary).deliveryID, snapshot.deliveryID)
        XCTAssertEqual(try XCTUnwrap(fallback).deliveryID, snapshot.deliveryID)
        XCTAssertEqual(try encoder.encode(primary), try encoder.encode(snapshot))
        XCTAssertEqual(try encoder.encode(primary), try encoder.encode(fallback))
    }

    func testLegacyProjectionSuppressesOnlyNowPlayingWhenStoppedOrCutOver() {
        let snapshot = NowPlayingSnapshot(
            title: "Fixture Track",
            artist: nil,
            album: nil,
            timestamp: Date(timeIntervalSince1970: 1_700_000_001)
        )

        XCTAssertNil(NowPlayingTelemetryProjection.legacySnapshot(
            snapshot, streamEnabled: false, legacyAllowed: true
        ))
        XCTAssertNil(NowPlayingTelemetryProjection.legacySnapshot(
            snapshot, streamEnabled: true, legacyAllowed: false
        ))
        XCTAssertEqual(
            NowPlayingTelemetryProjection.legacySnapshot(
                snapshot, streamEnabled: true, legacyAllowed: true
            )?.deliveryID,
            snapshot.deliveryID
        )
    }
}
