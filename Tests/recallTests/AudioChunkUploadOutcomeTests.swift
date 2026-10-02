import XCTest
import SwiftData
@testable import recall

@MainActor
final class AudioChunkUploadOutcomeTests: XCTestCase {
    func testProductionDiscardTransitionsClearPriorUploadTimestampForEveryReason() {
        let manager = UploadManager()
        let reasons: [AudioChunk.DiscardReason] = [.short, .noise, .empty, .expired, .retryExhausted]

        for reason in reasons {
            let chunk = AudioChunk(filePath: "/tmp/\(reason.rawValue).caf", fileName: "\(reason.rawValue).caf", startedAt: .now)
            chunk.uploadedAt = Date(timeIntervalSince1970: 123)
            manager.markDiscarded(chunk, reason: reason)

            XCTAssertEqual(chunk.uploadStatus, .discarded)
            XCTAssertEqual(chunk.discardReason, reason)
            XCTAssertNil(chunk.uploadedAt)
        }
    }

    func testProductionSuccessTransitionSetsTimestampAndClearsDiscardReason() {
        let manager = UploadManager()
        let chunk = AudioChunk(filePath: "/tmp/chunk.caf", fileName: "chunk.caf", startedAt: .now)
        chunk.uploadStatus = .discarded
        chunk.discardReason = .empty
        let completedAt = Date(timeIntervalSince1970: 456)

        manager.markUploaded(chunk, at: completedAt)

        XCTAssertEqual(chunk.uploadStatus, .uploaded)
        XCTAssertNil(chunk.discardReason)
        XCTAssertEqual(chunk.uploadedAt, completedAt)
    }

    func testRefreshCountsExcludesDiscardedTerminalRows() throws {
        let schema = Schema([AudioChunk.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        for status in [AudioChunk.UploadStatus.pending, .uploaded, .failed, .discarded] {
            let chunk = AudioChunk(filePath: "/tmp/\(status.rawValue).caf", fileName: status.rawValue, startedAt: .now)
            chunk.uploadStatus = status
            context.insert(chunk)
        }
        try context.save()

        let manager = UploadManager()
        manager.refreshCounts(modelContext: context)

        XCTAssertEqual(manager.pendingCount, 1)
        XCTAssertEqual(manager.uploadedCount, 1)
        XCTAssertEqual(manager.failedCount, 1)
    }

    func testLegacyUploadedRowWithoutReasonRemainsReadable() throws {
        let schema = Schema([AudioChunk.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        let chunk = AudioChunk(filePath: "/tmp/legacy.caf", fileName: "legacy.caf", startedAt: .now)
        chunk.uploadStatus = .uploaded
        chunk.uploadedAt = Date(timeIntervalSince1970: 123)
        chunk.discardReasonRaw = nil
        context.insert(chunk)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<AudioChunk>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].uploadStatus, .uploaded)
        XCTAssertNil(fetched[0].discardReason)
    }
}
