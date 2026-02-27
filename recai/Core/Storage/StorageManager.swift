import Foundation
import SwiftData
import OSLog

actor StorageManager {
    static let shared = StorageManager()
    private let logger = Logger(subsystem: "com.recai", category: "Storage")

    private init() {}

    func enforceStorageCap(modelContext: ModelContext) async {
        let capBytes = Int64(AppSettings.shared.storageCapMB) * 1024 * 1024
        let currentSize = await ChunkFileManager.shared.totalChunksSize()

        guard currentSize > capBytes else { return }

        logger.info("Storage \(currentSize) exceeds cap \(capBytes), cleaning up")

        let uploaded = AudioChunk.UploadStatus.uploaded.rawValue
        let descriptor = FetchDescriptor<AudioChunk>(
            predicate: #Predicate { $0.uploadStatusRaw == uploaded },
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )

        guard let uploaded = try? modelContext.fetch(descriptor) else { return }

        var freed: Int64 = 0
        let excess = currentSize - capBytes

        for chunk in uploaded {
            guard freed < excess else { break }
            do {
                try await ChunkFileManager.shared.deleteChunk(at: chunk.filePath)
                freed += chunk.fileSize
                modelContext.delete(chunk)
                logger.debug("Deleted uploaded chunk: \(chunk.fileName)")
            } catch {
                logger.error("Failed to delete chunk \(chunk.fileName): \(error)")
            }
        }

        try? modelContext.save()
        logger.info("Freed \(freed) bytes")
    }
}
