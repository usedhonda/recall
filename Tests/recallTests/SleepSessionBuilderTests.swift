import XCTest
@testable import recall

final class SleepSessionBuilderTests: XCTestCase {
    private func sample(_ startHour: Double, _ endHour: Double, _ stage: String, source: String = "ring") -> SleepSampleInput {
        SleepSampleInput(
            start: Date(timeIntervalSince1970: startHour * 3600),
            end: Date(timeIntervalSince1970: endHour * 3600),
            stage: stage, source: source, sourceBundleId: source
        )
    }

    func testAGapOfThreeHoursSeparatesTwoSleepPeriods() {
        let sessions = SleepSessionBuilder.sessions(from: [
            sample(0, 2, "asleepCore"), sample(2, 3, "asleepDeep"),
            sample(6, 7, "asleepREM"),
        ])
        XCTAssertEqual(sessions.map(\.totalMinutes), [180, 60])
        XCTAssertEqual(sessions[0].deepMinutes, 60)
    }

    func testARewrittenOverlapCountsOnce() {
        let sessions = SleepSessionBuilder.sessions(from: [
            sample(0, 2, "asleepCore"), sample(1, 3, "asleepCore"),
        ])
        XCTAssertEqual(sessions.first?.totalMinutes, 180)
    }

    func testSourcesStayApartAndInBedIsNotSleep() {
        let sessions = SleepSessionBuilder.sessions(from: [
            sample(0, 8, "inBed"),
            sample(1, 2, "asleepCore"),
            sample(1, 2, "asleepCore", source: "phone"),
        ])
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.map(\.totalMinutes), [60, 60])
        XCTAssertEqual(sessions[0].end, Date(timeIntervalSince1970: 2 * 3600))
    }
}
