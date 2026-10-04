import XCTest
@testable import recall

/// The whole point of the diagnostic is telling apart codes that read the same in the
/// localized sentence. A mis-decoded code would send the next investigation the wrong way.
final class AudioErrorDiagnosticTests: XCTestCase {
    private func code(_ value: Int) -> String {
        NSError(domain: NSOSStatusErrorDomain, code: value).audioDiagnostic
    }

    func testTheCodesSeenOnThisDeviceDecode() {
        XCTAssertTrue(code(561_017_449).contains("'!pri'"), code(561_017_449))   // lower priority than a call
        XCTAssertTrue(code(560_557_684).contains("'!int'"), code(560_557_684))   // may not interrupt
        XCTAssertTrue(code(2_003_329_396).contains("'what'"), code(2_003_329_396)) // media server
    }

    func testPlainNumbersStayNumbers() {
        let text = code(-50)
        XCTAssertTrue(text.contains("-50"), text)
        XCTAssertFalse(text.contains("'"), text)
    }

    func testOnlySessionRefusalsAreTreatedAsWaitNotRebuild() {
        func refusal(_ value: Int) -> String? {
            AudioSessionManager.activationRefusal(NSError(domain: NSOSStatusErrorDomain, code: value))
        }
        XCTAssertEqual(refusal(561_017_449), "insufficientPriority")      // '!pri': what held the mic on 2026-10-03
        XCTAssertEqual(refusal(560_557_684), "cannotInterruptOthers")     // '!int'
        XCTAssertNil(refusal(2_003_329_396))                              // 'what': an engine fault, still rebuilt
        XCTAssertNil(refusal(-50))
    }
}
