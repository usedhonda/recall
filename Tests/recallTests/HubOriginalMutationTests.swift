import XCTest
@testable import recall

final class HubOriginalMutationTests: XCTestCase {
    @MainActor
    func testGlassesCopyBlocksConcurrentOutboxAdmissionUntilItsOwnRelease() async throws {
        let defaults = UserDefaults.standard
        let key = "hub.enabledRoutes.v1"
        let previous = defaults.object(forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set([HubRecallRoute.glassesOriginal.rawValue], forKey: key)
        let service = HubDeliveryService()
        let copy = try XCTUnwrap(service.beginOriginalMutation(.glassesOriginal))
        do {
            _ = try await service.admit(route: .glassesOriginal, observationID: "fixture",
                occurredAt: Date(timeIntervalSince1970: 1), timeBasis: "captured_at",
                sourcePayloadJSON: Data("{}".utf8), originalBytes: Data([1]))
            XCTFail("outbox admission must not race the source size snapshot")
        } catch { XCTAssertEqual(error as? HubDurableOutbox.Failure, .laneFull) }
        service.finishOriginalMutation(.glassesOriginal, token: UUID())
        XCTAssertNil(service.beginOriginalMutation(.glassesOriginal))
        service.finishOriginalMutation(.glassesOriginal, token: copy)
        let next = try XCTUnwrap(service.beginOriginalMutation(.glassesOriginal))
        service.finishOriginalMutation(.glassesOriginal, token: copy)
        XCTAssertNil(service.beginOriginalMutation(.glassesOriginal))
        service.finishOriginalMutation(.glassesOriginal, token: next)
    }
}
