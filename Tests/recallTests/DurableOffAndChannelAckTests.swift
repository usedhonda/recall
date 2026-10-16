import UIKit
import XCTest
@testable import recall

@MainActor
final class DurableOffAndChannelAckTests: XCTestCase {
    func testDeploymentLaunchKeepsAStoredStopThroughTheActivationCallback() {
        let key = LaunchContext.preserveOffEnvironmentKey
        func background(_ state: UIApplication.State, _ env: [String: String], stop: Bool) -> Bool {
            LaunchContext.isBackgroundLaunch(applicationState: state, environment: env, userStopIntent: stop)
        }
        XCTAssertTrue(background(.inactive, [key: "1"], stop: true), "deployment launch with a stored stop stays silent")
        XCTAssertFalse(background(.inactive, [key: "1"], stop: false), "no stop stored: nothing to preserve")
        XCTAssertFalse(background(.inactive, [:], stop: true), "a normal launch is unchanged")
        XCTAssertFalse(background(.active, [key: "0"], stop: true), "only the exact flag counts")

        // The same process later receives scene-active: the caller's decision must not run
        // normal startup (which clears the stop and starts recording).
        XCTAssertEqual(LaunchContext.foregroundAction(deploymentPreservesOff: true), .independentStreamsOnly)
        XCTAssertEqual(LaunchContext.foregroundAction(deploymentPreservesOff: false), .normalStartup)
    }

    func testAnOffReachesTheDurableStopAndTheIdlePendingStartBeforeAnExplicitOnResumes() async {
        let state = RecordingStateManager.shared
        let savedRecording = state.isRecording
        let savedStop = state.userStopIntent
        defer { state.isRecording = savedRecording; state.userStopIntent = savedStop }

        let model = RecordingViewModel()
        state.userStopIntent = false
        state.isRecording = true
        let pendingStart = model.recordingOperationGeneration.token
        XCTAssertTrue(model.acceptsRecordingOperation(pendingStart), "a start waiting in back-off is accepted before the OFF")

        // The Control Center caller: the stop is durable before any observer runs.
        state.applyExternalToggle(false)
        XCTAssertTrue(state.userStopIntent, "OFF saves the stop even if the app process never runs")
        XCTAssertFalse(state.isRecording)

        // The app handles the toggle while the engine is idle (nothing "active").
        await model.handleExternalToggle()
        XCTAssertFalse(model.acceptsRecordingOperation(pendingStart),
                       "the pending start must not resume capture after the OFF")

        // A later explicit ON is not refused by the stop that was kept.
        state.applyExternalToggle(true)
        XCTAssertTrue(state.isRecording)
        model.recordingOperationGeneration.invalidate()
        state.userStopIntent = false   // what start() does first
        XCTAssertTrue(model.acceptsRecordingOperation(model.recordingOperationGeneration.token))
    }

    func testAnOlderAcknowledgementDoesNotClearANewerChannelChangeAndAFailureStaysDirty() {
        let suite = UserDefaults(suiteName: "channel-ack-test-\(UUID().uuidString)")!
        func dirty(_ current: String) -> Bool {
            ChannelAckLedger.isDirty(current: current, acked: suite.string(forKey: ChannelAckLedger.key("health")))
        }
        ChannelAckLedger.record([("health", "active")], in: suite)
        XCTAssertFalse(dirty("active"))

        // Health goes off; the send of that snapshot fails: nothing is recorded.
        XCTAssertTrue(dirty("gated_by_user"))
        XCTAssertTrue(dirty("gated_by_user"), "after the failed send the next tick still sees the edge")

        // A retained OLDER payload (health=active) is acknowledged while health is now off.
        ChannelAckLedger.record([("health", "active")], in: suite)
        XCTAssertTrue(dirty("gated_by_user"), "the old acknowledgement must not erase the newer edge")

        // The payload that carried the new state is acknowledged.
        ChannelAckLedger.record([("health", "gated_by_user")], in: suite)
        XCTAssertFalse(dirty("gated_by_user"))
    }

    func testAFailedFirstSendIsNotTurnedIntoAnAcknowledgementByTheNextTick() {
        let suite = UserDefaults(suiteName: "channel-ack-test-\(UUID().uuidString)")!
        let observedKey = "channelState.health"
        // Tick 1 on a new install: migration runs (nothing to carry), the observation is saved,
        // the send fails.
        ChannelAckLedger.migrateOnce(observed: [("health", suite.string(forKey: observedKey))], in: suite)
        suite.set("gated_by_user", forKey: observedKey)
        // Tick 2: the unacknowledged observation must not become the acknowledged state.
        ChannelAckLedger.migrateOnce(observed: [("health", suite.string(forKey: observedKey))], in: suite)
        XCTAssertNil(suite.string(forKey: ChannelAckLedger.key("health")),
                     "still unacknowledged: the tick keeps treating it as a first run")

        // An older build's observation, carried over once at the first tick of this build.
        let upgraded = UserDefaults(suiteName: "channel-ack-test-\(UUID().uuidString)")!
        upgraded.set("active", forKey: observedKey)
        ChannelAckLedger.migrateOnce(observed: [("health", upgraded.string(forKey: observedKey))], in: upgraded)
        XCTAssertEqual(upgraded.string(forKey: ChannelAckLedger.key("health")), "active")
    }
}
