import Foundation

actor ChunkFileManager {
    static let shared = ChunkFileManager()

    private let chunksDirectory: URL

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        chunksDirectory = docs.appendingPathComponent("chunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
    }

    var chunksDirectoryURL: URL { chunksDirectory }

    func generateChunkURL(startedAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let name = formatter.string(from: startedAt) + ".m4a"
        return chunksDirectory.appendingPathComponent(name)
    }

    func deleteChunk(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func fileSize(at path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    func totalChunksSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: chunksDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }

        return files.reduce(Int64(0)) { sum, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return sum + Int64(size)
        }
    }

    func allChunkFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: chunksDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ))?.sorted {
            let d1 = (try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            let d2 = (try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            return d1 < d2
        } ?? []
    }
}
