import Foundation

/// Conservative admission guards for source originals. Guards never delete data;
/// callers keep acquisition pending when a lane is full.
actor OriginalCapacity {
    static let shared = OriginalCapacity()
    private let glassesCap = Int64(512) * 1024 * 1024
    private let audioReserve = Int64(1024) * 1024

    func canStartAudioChunk() async -> Bool {
        let cap = Int64(max(1, AppSettings.shared.storageCapMB)) * 1024 * 1024
        let used = await ChunkFileManager.shared.totalChunksSize()
        return used + audioReserve <= cap
    }

    func canImportGlasses(bytes: Int64) -> Bool {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let media = docs.appendingPathComponent("media", isDirectory: true)
        let used = (try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: [.fileSizeKey]))?.reduce(Int64(0)) {
            $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        } ?? 0
        return used + bytes <= glassesCap
    }
}
