import XCTest
import SwiftData
@testable import recall

/// A #Predicate that force-unwraps an optional date throws `unsupportedPredicate`, and the
/// `try?` around the fetch turned that into "nothing pending". These pin the production
/// queries that used to have that shape.
@MainActor
final class OptionalDatePredicateTests: XCTestCase {
    func testMediaSelectionFindsAFreshPendingChunkWithAndWithoutHub() throws {
        let schema = Schema([MediaChunk.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        context.insert(MediaChunk(filePath: "/tmp/m.jpg", fileName: "m.jpg", mediaType: .image, capturedAt: .now,
                                  photoLocalIdentifier: "p1", fileSize: 1, pixelWidth: 1, pixelHeight: 1, uti: "public.jpeg",
                                  exifMake: "", exifModel: "", source: .photos, matchConfidence: .confirmed))
        try context.save()

        for hubEnabled in [false, true] {
            XCTAssertEqual(MediaUploadManager.shared.nextPendingChunk(context: context, hubEnabled: hubEnabled)?.fileName, "m.jpg", "hubEnabled=\(hubEnabled)")
        }
    }

    func testStalledUploadingChunkIsResetToPending() throws {
        let schema = Schema([AudioChunk.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]))
        let stalled = AudioChunk(filePath: "/tmp/s.caf", fileName: "s.caf", startedAt: .now)
        stalled.uploadStatus = .uploading
        stalled.lastUploadAttempt = Date().addingTimeInterval(-600)
        let active = AudioChunk(filePath: "/tmp/a.caf", fileName: "a.caf", startedAt: .now)
        active.uploadStatus = .uploading
        active.lastUploadAttempt = Date()
        context.insert(stalled)
        context.insert(active)
        try context.save()

        UploadManager().resetStaleUploads(modelContext: context)

        XCTAssertEqual(stalled.uploadStatus, .pending)
        XCTAssertEqual(active.uploadStatus, .uploading)
    }

    func testMediaStartupRecoversMovedInFlightRowsAndPreservesOtherOwnership() throws {
        let schema = Schema([MediaChunk.self])
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("moved.jpg"))

        func insert(_ name: String, status: MediaUploadStatus) -> MediaChunk {
            let chunk = MediaChunk(filePath: "/old-container/Documents/media/\(name)", fileName: name,
                mediaType: .image, capturedAt: .now, photoLocalIdentifier: name, fileSize: 3,
                pixelWidth: 1, pixelHeight: 1, uti: "public.jpeg", exifMake: "", exifModel: "",
                source: .glasses, matchConfidence: .confirmed)
            chunk.uploadStatus = status
            context.insert(chunk)
            return chunk
        }
        let moved = insert("moved.jpg", status: .uploading)
        moved.uploadAttempts = 2
        moved.hubExternalID = "fixture-hub-identity"
        let missing = insert("missing.jpg", status: .failed)
        missing.uploadAttempts = 3
        let uploaded = insert("uploaded.jpg", status: .uploaded)
        let deliveredAt = Date()
        uploaded.uploadedAt = deliveredAt
        try context.save()

        XCTAssertEqual(try MediaUploadManager.shared.recoverPersistedQueue(context: context, mediaDirectory: directory), 1)
        XCTAssertEqual(moved.filePath, directory.appendingPathComponent("moved.jpg").path)
        XCTAssertEqual(moved.uploadStatus, .pending)
        XCTAssertEqual(moved.uploadAttempts, 2)
        XCTAssertEqual(moved.hubExternalID, "fixture-hub-identity")
        XCTAssertEqual(missing.uploadStatus, .failed)
        XCTAssertEqual(missing.filePath, "/old-container/Documents/media/missing.jpg")
        XCTAssertEqual(missing.uploadAttempts, 3)
        XCTAssertEqual(uploaded.uploadStatus, .uploaded)
        XCTAssertEqual(uploaded.uploadedAt, deliveredAt)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("moved.jpg")), Data([1, 2, 3]))

        let reopened = ModelContext(container)
        let saved = try XCTUnwrap(reopened.fetch(FetchDescriptor<MediaChunk>()).first { $0.id == moved.id })
        XCTAssertEqual(saved.uploadStatus, .pending)
        XCTAssertEqual(saved.filePath, moved.filePath)
        XCTAssertEqual(try MediaUploadManager.shared.recoverPersistedQueue(context: reopened, mediaDirectory: directory), 0)
    }
}
