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
}
