import XCTest
@testable import recall

/// The server alarms on some of these states and deliberately not on others, so the
/// mapping is a contract: a user stop reported as internal would nag the owner for
/// switching recording off, and an internal stop reported as a user stop would hide
/// exactly the outage the signal exists to reveal.
final class AudioStateSignalTests: XCTestCase {
    func testTheOwnersSwitchWinsOverWhateverTheEngineIsDoing() {
        for engine in [AudioStateSignal.Engine.none, .idle, .listening, .recording, .paused] {
            XCTAssertEqual(
                AudioStateSignal.describe(toggleOn: false, engine: engine, activationBlocked: true),
                "stopped:user"
            )
        }
    }

    func testSwitchOnButNothingRunningIsNotTheOwnersDoing() {
        XCTAssertEqual(AudioStateSignal.describe(toggleOn: true, engine: .none, activationBlocked: false), "stopped:internal")
        XCTAssertEqual(AudioStateSignal.describe(toggleOn: true, engine: .idle, activationBlocked: false), "stopped:internal")
    }

    func testARefusedResumeNamesItsReason() {
        XCTAssertEqual(
            AudioStateSignal.describe(toggleOn: true, engine: .paused, activationBlocked: true),
            "blocked:cannotInterruptOthers"
        )
        XCTAssertEqual(
            AudioStateSignal.describe(toggleOn: true, engine: .paused, activationBlocked: false),
            "blocked:interrupted"
        )
    }

    func testListeningAndRecordingAreOneHealthClass() {
        // Otherwise every sentence would send a message.
        XCTAssertEqual(AudioStateSignal.healthClass(of: "listening"), "capturing")
        XCTAssertEqual(AudioStateSignal.healthClass(of: "recording"), "capturing")
        XCTAssertEqual(AudioStateSignal.healthClass(of: "blocked:cannotInterruptOthers"), "blocked:cannotInterruptOthers")
        XCTAssertEqual(AudioStateSignal.healthClass(of: "stopped:user"), "stopped:user")
    }
}
