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

    func testChunkPathFromAnOldContainerIsRepointedToTheCurrentChunksDirectory() throws {
        let context = try makeContext()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1]).write(to: dir.appendingPathComponent("b.caf"))
        let chunk = AudioChunk(filePath: "/var/mobile/Containers/Data/Application/OLD/Documents/chunks/b.caf", fileName: "b.caf", startedAt: .now)
        context.insert(chunk)
        try context.save()

        XCTAssertEqual(UploadManager().repairMovedChunkPaths(modelContext: context, chunksDirectory: dir), 1)
        XCTAssertEqual(chunk.filePath, dir.appendingPathComponent("b.caf").path)
    }
}
