import Foundation
import OSLog
import Photos
import SwiftData

@MainActor
final class MediaImporter {
    private static let logger = Logger(subsystem: "com.recall", category: "MediaImporter")

    private let mediaDirectory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mediaDirectory = docs.appendingPathComponent("media", isDirectory: true)
        try? FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
    }

    enum ImportError: Error {
        case noResources
        case copyFailed(String)
        case alreadyImported
    }

    /// Imports a confirmed/probable Meta-glass image asset into the app container.
    /// Returns the created MediaChunk on success, or nil if already imported (deduped).
    func importImage(
        asset: PHAsset,
        metadata: MetaGlassFilter.ExtractedMetadata,
        confidence: MediaMatchConfidence,
        modelContext: ModelContext
    ) async throws -> MediaChunk? {
        // Dedup: skip if a MediaChunk with this localIdentifier already exists.
        let localId = asset.localIdentifier
        let descriptor = FetchDescriptor<MediaChunk>(
            predicate: #Predicate { $0.photoLocalIdentifier == localId }
        )
        if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty {
            return nil
        }

        guard let resource = bestImageResource(for: asset) else {
            throw ImportError.noResources
        }

        let fileName = filename(for: asset, suggestedExtension: extensionFromUTI(metadata.uti) ?? "heic")
        let destination = mediaDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        do {
            try await PHAssetResourceManager.default().writeData(for: resource, toFile: destination, options: options)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        let chunk = MediaChunk(
            filePath: destination.path,
            fileName: fileName,
            mediaType: .image,
            capturedAt: asset.creationDate ?? Date(),
            photoLocalIdentifier: localId,
            fileSize: fileSize,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            uti: metadata.uti,
            exifMake: metadata.make,
            exifModel: metadata.model,
            source: .glasses,
            matchConfidence: confidence,
            latitude: asset.location?.coordinate.latitude,
            longitude: asset.location?.coordinate.longitude
        )

        modelContext.insert(chunk)
        try modelContext.save()

        Self.logger.info("Imported image: \(fileName) (localId=\(localId), confidence=\(confidence.rawValue))")
        ActivityLogger.shared.log(.telemetry, "[photo] imported \(fileName) localId=\(localId) make=\(metadata.make) model=\(metadata.model) res=\(metadata.pixelWidth)x\(metadata.pixelHeight) confidence=\(confidence.rawValue)")
        return chunk
    }

    private func bestImageResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        // Prefer the original photo (non-edited) when available.
        if let original = resources.first(where: { $0.type == .photo }) {
            return original
        }
        if let fullSize = resources.first(where: { $0.type == .fullSizePhoto }) {
            return fullSize
        }
        return resources.first
    }

    private func filename(for asset: PHAsset, suggestedExtension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: asset.creationDate ?? Date())
        let safeId = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
            .components(separatedBy: CharacterSet(charactersIn: "/.")).joined(separator: "_")
            .prefix(20)
        return "meta_\(timestamp)_\(safeId).\(ext)"
    }

    private func extensionFromUTI(_ uti: String) -> String? {
        switch uti.lowercased() {
        case "public.heic", "public.heif": return "heic"
        case "public.jpeg": return "jpg"
        case "public.png": return "png"
        case "public.mpeg-4", "com.apple.quicktime-movie": return "mov"
        default: return nil
        }
    }
}
