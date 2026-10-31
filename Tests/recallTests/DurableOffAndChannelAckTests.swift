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
        // Ordering: the active callback marks the user foreground BEFORE the startup task reads
        // shouldStaySilent. With the deployment flag that must still be silent (start 0).
        let savedFlag = LaunchContext.deploymentPreservesOff
        let savedForeground = LaunchContext.userDidForeground
        let savedBackground = LaunchContext.launchedInBackground
        defer {
            LaunchContext.deploymentPreservesOff = savedFlag
            LaunchContext.userDidForeground = savedForeground
            LaunchContext.launchedInBackground = savedBackground
        }
        LaunchContext.deploymentPreservesOff = true
        LaunchContext.launchedInBackground = true
        LaunchContext.userDidForeground = true            // scene-active callback ran first
        XCTAssertTrue(LaunchContext.shouldStaySilent, "task after the active callback must not start recording")
        LaunchContext.userDidForeground = false           // task ran first
        XCTAssertTrue(LaunchContext.shouldStaySilent)
        LaunchContext.deploymentPreservesOff = false
        LaunchContext.userDidForeground = true
        LaunchContext.launchedInBackground = false
        RecordingStateManager.shared.userStopIntent = false
        XCTAssertFalse(LaunchContext.shouldStaySilent, "an ordinary foreground launch is unchanged")

        XCTAssertEqual(LaunchContext.foregroundAction(deploymentPreservesOff: true, ownerStopped: false), .independentStreamsOnly)
        XCTAssertEqual(LaunchContext.foregroundAction(deploymentPreservesOff: false, ownerStopped: false), .normalStartup)

        // Opening the app is not an ON: a stored stop outlives the foreground.
        XCTAssertEqual(LaunchContext.foregroundAction(deploymentPreservesOff: false, ownerStopped: true), .independentStreamsOnly)
        let state = RecordingStateManager.shared
        let savedStop = state.userStopIntent
        defer { state.userStopIntent = savedStop }
        state.userStopIntent = true
        XCTAssertTrue(LaunchContext.shouldStaySilent, "a foreground launch must not start over the owner's stop")
    }

    func testAnOffReachesTheDurableStopAndTheIdlePendingStartBeforeAnExplicitOnResumes() async {
        let state = RecordingStateManager.shared
        let savedRecording = state.isRecording
        let savedStop = state.userStopIntent
        defer { state.isRecording = savedRecording; state.userStopIntent = savedStop }

        let model = RecordingViewModel()
        state.userStopIntent = false
        state.isRecording = true
        let engine = AudioRecordingEngine()
        model.engine = engine
        let engineStart = engine.startGenerationToken
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

        XCTAssertNotEqual(engine.startGenerationToken, engineStart,
                          "a first Engine.start() still suspended must also be invalidated, not only the VM operation")

        // A later explicit ON is not refused by the stop that was kept.
        state.applyExternalToggle(true)
        XCTAssertTrue(state.isRecording)
        XCTAssertFalse(state.userStopIntent, "an ON saved while the app is not running must survive until it launches")
        model.recordingOperationGeneration.invalidate()
        XCTAssertTrue(model.acceptsRecordingOperation(model.recordingOperationGeneration.token))
    }

    func testAnOlderAcknowledgementDoesNotClearANewerChannelChangeAndAFailureStaysDirty() {
        let suite = UserDefaults(suiteName: "channel-ack-test-\(UUID().uuidString)")!
        func dirty(_ current: String) -> Bool {
            ChannelAckLedger.isDirty(current: current, acked: suite.string(forKey: ChannelAckLedger.key("health")))
        }
        ChannelAckLedger.record([("health", "active")], in: suite)
        XCTAssertFalse(dirty("active"))
        XCTAssertFalse(ChannelAckLedger.isDirty(current: "gated_by_user", acked: nil),
                       "never acknowledged: not an edge, the tick's first-run rule keeps it pending until ACK")

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

    func testARetainedPayloadIsSentAgainEvenWhenTheStateFlippedBackToTheAcknowledgedOne() {
        let suite = UserDefaults(suiteName: "channel-ack-test-\(UUID().uuidString)")!
        ChannelAckLedger.record([("health", "active")], in: suite)
        // Health goes off: the payload is retained and its send fails.
        suite.set("{retained}", forKey: ChannelAckLedger.pendingPayloadKey)
        XCTAssertTrue(ChannelAckLedger.isDirty(current: "gated_by_user", acked: "active"))
        // Health goes back on before the next tick: current == acknowledged, no edge, level recent.
        let dirtyNow = ChannelAckLedger.isDirty(current: "active", acked: suite.string(forKey: ChannelAckLedger.key("health")))
        XCTAssertFalse(dirtyNow, "the ABA flip hides the edge from the dirty check")
        let pending = suite.string(forKey: ChannelAckLedger.pendingPayloadKey) != nil
        XCTAssertTrue(ChannelAckLedger.sendEligible(edge: dirtyNow, level: false, hasPending: pending),
                      "the retained payload must still go out on the next tick, not wait for the hourly level")
        suite.removeObject(forKey: ChannelAckLedger.pendingPayloadKey)   // acknowledged
        XCTAssertFalse(ChannelAckLedger.sendEligible(edge: false, level: false,
                       hasPending: suite.string(forKey: ChannelAckLedger.pendingPayloadKey) != nil))
    }

    /// A first start() held on the shared finalization barrier, an OFF, then an explicit ON.
    /// `secondOff` adds a newer OFF while that ON is still waiting.
    private func runHeldStart(secondOff: Bool) async -> (onEndedAfterOldStart: Bool?, userStopped: Bool) {
        var release: CheckedContinuation<Void, Never>?
        AudioFinalizationQueue.shared.enqueue { await withCheckedContinuation { release = $0 } }
        await Task.yield()

        let engine = AudioRecordingEngine()
        var oldStartReturned = false
        let oldStart = Task { @MainActor in
            try? await engine.start()
            oldStartReturned = true
        }
        await Task.yield()
        engine.cancelPendingStart()                      // OFF 1

        var onEndedAfterOldStart: Bool?
        let explicitOn = Task { @MainActor in
            try? await engine.start()                    // the ON, waiting on the old start
            onEndedAfterOldStart = oldStartReturned
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(onEndedAfterOldStart, "the ON must wait for the old start, not return at once as if started")
        if secondOff { engine.cancelPendingStart() }     // OFF 2 while the ON waits

        release?.resume()
        await oldStart.value
        await explicitOn.value
        let userStopped = engine.userStopped
        engine.stop(intentional: false)
        return (onEndedAfterOldStart, userStopped)
    }

    func testAnExplicitOnWaitsForTheOldStartAndAnOffThatArrivesWhileItWaitsStillWins() async {
        let plain = await runHeldStart(secondOff: false)
        XCTAssertEqual(plain.onEndedAfterOldStart, true, "the ON returns only after the old start ended")
        XCTAssertFalse(plain.userStopped, "and it then really started (stop flag cleared)")

        let withOff2 = await runHeldStart(secondOff: true)
        XCTAssertEqual(withOff2.onEndedAfterOldStart, true)
        XCTAssertTrue(withOff2.userStopped, "OFF 2 invalidated the waiting ON: it must not take a fresh generation and start")
    }
}
