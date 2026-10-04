import XCTest
import SwiftData
@testable import recall

@MainActor
final class FetchNextPendingQueryTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([AudioChunk.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    func testFreshPendingChunkIsSelectedWithAndWithoutHub() throws {
        let context = try makeContext()
        let chunk = AudioChunk(filePath: "/tmp/a.caf", fileName: "a.caf", startedAt: .now)
        context.insert(chunk)
        try context.save()

        for hubEnabled in [false, true] {
            XCTAssertEqual(UploadManager().nextPendingChunk(modelContext: context, hubEnabled: hubEnabled)?.fileName, "a.caf", "hubEnabled=\(hubEnabled)")
        }
    }
}
