import CoreLocation
import Foundation
import Observation
import SwiftData
import UIKit

/// Receives glasses photos handed off by vibeterm via a shared App Group drop folder.
/// vibeterm receives the photo from the glasses (DAT) at capture time and writes it
/// here; recall imports it (source=.glasses) and uploads to /ingest-media — same as
/// the PhotoKit path, but without the ~1h photo-library sync lag and without recall
/// taking the DAT registration slot. Dormant (empty drain) until vibeterm produces.
@Observable
@MainActor
final class GlassesHandoffReceiver {
    private static let appGroupID = "group.com.example.recall"
    private static let dropFolderName = "glasses-handoff"
    private static let notificationName = "com.example.recall.glassesPhotoDropped"
    private static let orphanAgeThreshold: TimeInterval = 600  // 10 min

    private(set) var isEnabled = false
    private(set) var totalImported = 0
    private(set) var lastImportedAt: Date?

    private var modelContainer: ModelContainer?
    private var darwinToken: DarwinNotificationToken?
    private var foregroundObserver: NSObjectProtocol?
    private var isDraining = false

    private let importer = MediaImporter()
    private let dropFolder: URL?

    init() {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
            let folder = container.appendingPathComponent(Self.dropFolderName, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            dropFolder = folder
        } else {
            dropFolder = nil
        }
    }

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    func start() {
        guard !isEnabled else { return }
        guard dropFolder != nil else {
            ActivityLogger.shared.log(.error, "[handoff] App Group container unavailable — receiver disabled")
            return
        }
        isEnabled = true
        ActivityLogger.shared.log(.telemetry, "[handoff] receiver started")

        // Fast nudge: vibeterm posts this Darwin notification after committing a pair.
        darwinToken = DarwinNotificationToken(name: Self.notificationName) { [weak self] in
            Task { @MainActor [weak self] in await self?.drain() }
        }
        // Recover notifications missed while suspended.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.drain() }
        }
        // Launch catch-up.
        Task { await drain() }
    }

    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        darwinToken = nil
        if let token = foregroundObserver {
            NotificationCenter.default.removeObserver(token)
            foregroundObserver = nil
        }
        ActivityLogger.shared.log(.telemetry, "[handoff] receiver stopped")
    }

    private struct HandoffManifest: Decodable {
        let captureId: String
        let capturedAt: String
        let mimeType: String
        let pixelWidth: Int
        let pixelHeight: Int
        let source: String
        let latitude: Double?
        let longitude: Double?
    }

    /// Drains the drop folder: GC orphans, import committed pairs, delete on success,
    /// kick the upload queue. Serialized so overlapping Darwin + foreground triggers
    /// don't double-process.
    func drain() async {
        guard isEnabled, !isDraining, let folder = dropFolder, let container = modelContainer else { return }
        isDraining = true
        defer { isDraining = false }

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        // 1. Orphan GC: a final image with no .json sidecar (producer crashed between
        //    the image rename and the sidecar rename), older than the age threshold.
        //    Age threshold avoids racing a pair that is mid-write.
        let now = Date()
        let sidecarBases = Set(entries.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent })
        for url in entries where ["jpg", "jpeg", "heic", "png"].contains(url.pathExtension.lowercased()) {
            guard !sidecarBases.contains(url.deletingPathExtension().lastPathComponent) else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
            if now.timeIntervalSince(mtime) > Self.orphanAgeThreshold {
                try? fm.removeItem(at: url)
                ActivityLogger.shared.log(.telemetry, "[handoff] GC orphan image \(url.lastPathComponent)")
            }
        }

        // 2. Process committed pairs — the .json sidecar is the commit marker.
        let context = ModelContext(container)
        var imported = 0
        for sidecar in entries where sidecar.pathExtension == "json" {
            guard let raw = try? Data(contentsOf: sidecar),
                  let manifest = try? JSONDecoder().decode(HandoffManifest.self, from: raw) else {
                continue
            }
            let safeId = manifest.captureId
                .components(separatedBy: CharacterSet(charactersIn: "/.:"))
                .joined(separator: "_")
            let imageURL = folder.appendingPathComponent("\(safeId).\(mimeExt(manifest.mimeType))")
            guard fm.fileExists(atPath: imageURL.path), let bytes = try? Data(contentsOf: imageURL) else {
                continue  // image missing/partial — retry on next drain
            }
            let capturedAt = ISO8601DateFormatter().date(from: manifest.capturedAt) ?? Date()
            // Geotag: prefer the sidecar's own coordinates (future-proofing); when
            // vibeterm ships nil (it dropped its location capability for App Store
            // privacy review), fall back to recall's current fix — recall is an
            // always-on location app and already geotags audio chunks the same way.
            let geo: (lat: Double, lon: Double)?
            if let slat = manifest.latitude, let slon = manifest.longitude {
                geo = (slat, slon)
            } else if let fix = TelemetryService.shared.locationManager.currentLocation {
                geo = (fix.coordinate.latitude, fix.coordinate.longitude)
            } else {
                geo = nil
            }
            do {
                let chunk = try importer.importGlassesPhoto(
                    data: bytes,
                    capturedAt: capturedAt,
                    captureId: manifest.captureId,
                    pixelWidth: manifest.pixelWidth,
                    pixelHeight: manifest.pixelHeight,
                    uti: mimeUTI(manifest.mimeType),
                    latitude: geo?.lat,
                    longitude: geo?.lon,
                    modelContext: context
                )
                if chunk != nil {
                    imported += 1
                    let src = manifest.latitude != nil ? "sidecar" : (geo != nil ? "recall-fix" : "none")
                    ActivityLogger.shared.log(.telemetry, "[handoff] geotag=\(src) captureId=\(manifest.captureId)")
                }
                // Import success OR dedup-nil both mean "recall owns it now" — delete.
                try? fm.removeItem(at: imageURL)
                try? fm.removeItem(at: sidecar)
            } catch {
                // Leave the pair for the next drain; a small folder bounds the blast.
                ActivityLogger.shared.log(.error, "[handoff] import failed captureId=\(manifest.captureId): \(error.localizedDescription)")
            }
        }

        if imported > 0 {
            totalImported += imported
            lastImportedAt = Date()
            MediaUploadManager.shared.startProcessing(modelContainer: container)
            ActivityLogger.shared.log(.telemetry, "[handoff] drain complete imported=\(imported)")
        }
    }

    private func mimeExt(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/heic", "image/heif": return "heic"
        case "image/png": return "png"
        default: return "jpg"
        }
    }

    private func mimeUTI(_ mime: String) -> String {
        switch mime.lowercased() {
        case "image/heic", "image/heif": return "public.heic"
        case "image/png": return "public.png"
        default: return "public.jpeg"
        }
    }
}
