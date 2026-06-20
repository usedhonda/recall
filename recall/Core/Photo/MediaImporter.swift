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
        // Cross-path dedup: the same shutter may already be imported via the handoff
        // (dat:<captureId>) before PhotoKit syncs ~1h later. Skip if so.
        if hasDuplicate(capturedAt: asset.creationDate ?? Date(), pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight, modelContext: modelContext) {
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

    // MARK: - Glasses Handoff (byte-based, no PHAsset)

    /// Imports a photo handed off by vibeterm (received from the glasses via DAT).
    /// Takes raw bytes + a stable captureId instead of a PHAsset — no photo library
    /// involved. Returns the created MediaChunk, or nil if a chunk with this captureId
    /// (or a same-shutter duplicate already imported via PhotoKit) already exists.
    func importGlassesPhoto(
        data: Data,
        capturedAt: Date,
        captureId: String,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        uti: String = "public.jpeg",
        latitude: Double? = nil,
        longitude: Double? = nil,
        modelContext: ModelContext
    ) throws -> MediaChunk? {
        // Stable, namespaced dedup key — identical across re-deliveries of the same
        // shutter event, so a re-drop dedupes instead of double-importing.
        let stableId = "dat:\(captureId)"
        let descriptor = FetchDescriptor<MediaChunk>(
            predicate: #Predicate { $0.photoLocalIdentifier == stableId }
        )
        if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty {
            return nil
        }
        // Cross-path dedup: the SAME physical photo may also arrive via PhotoKit
        // (~1h later) under a PHAsset id. Skip if a same-shutter chunk already exists.
        if hasDuplicate(capturedAt: capturedAt, pixelWidth: pixelWidth, pixelHeight: pixelHeight, modelContext: modelContext) {
            return nil
        }

        let ext = extensionFromUTI(uti) ?? "jpg"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = formatter.string(from: capturedAt)
        let safeId = captureId.components(separatedBy: CharacterSet(charactersIn: "/.:")).joined(separator: "_").prefix(24)
        let fileName = "glasses_\(timestamp)_\(safeId).\(ext)"
        let destination = mediaDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try data.write(to: destination, options: .atomic)

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? Int64(data.count)

        let chunk = MediaChunk(
            filePath: destination.path,
            fileName: fileName,
            mediaType: .image,
            capturedAt: capturedAt,
            photoLocalIdentifier: stableId,
            fileSize: fileSize,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            uti: uti,
            exifMake: "Meta AI",
            exifModel: "Ray-Ban Meta",
            source: .glasses,
            matchConfidence: .confirmed,
            latitude: latitude,
            longitude: longitude
        )

        modelContext.insert(chunk)
        try modelContext.save()

        Self.logger.info("Imported glasses photo (handoff): \(fileName) captureId=\(captureId)")
        ActivityLogger.shared.log(.telemetry, "[photo] imported (handoff) \(fileName) captureId=\(captureId) bytes=\(data.count)")
        return chunk
    }

    /// Cross-path dedup: the same shutter event can arrive via both the handoff
    /// (`dat:<captureId>`) and PhotoKit (PHAsset id). Match on `capturedAt ±3s` AND
    /// exact pixel dimensions. fileSize is unreliable across HEIC/JPEG transcode, so
    /// it is intentionally NOT used. No-ops when dimensions are unknown (0).
    private func hasDuplicate(capturedAt: Date, pixelWidth: Int, pixelHeight: Int, modelContext: ModelContext) -> Bool {
        guard pixelWidth > 0, pixelHeight > 0 else { return false }
        let lo = capturedAt.addingTimeInterval(-3)
        let hi = capturedAt.addingTimeInterval(3)
        let descriptor = FetchDescriptor<MediaChunk>(
            predicate: #Predicate {
                $0.capturedAt >= lo && $0.capturedAt <= hi
                    && $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight
            }
        )
        if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty {
            return true
        }
        return false
    }
}
