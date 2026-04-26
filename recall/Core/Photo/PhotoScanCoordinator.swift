import Foundation
import Observation
import OSLog
import Photos
import SwiftData
import UIKit

@Observable
@MainActor
final class PhotoScanCoordinator: NSObject {
    private static let logger = Logger(subsystem: "com.recall", category: "PhotoScanCoordinator")
    private static let pollInterval: TimeInterval = 5 * 60       // 5 min
    private static let initialLookback: TimeInterval = 7 * 24 * 3600  // 7 days on first scan
    private static let overlapWindow: TimeInterval = 30 * 60     // 30 min
    private static let lastScanKey = "photoScan.lastScanAt"
    private static let recentImportWindow: TimeInterval = 3600   // 1h

    private(set) var isEnabled = false
    private(set) var lastScanAt: Date?
    private(set) var totalImported: Int = 0
    private(set) var lastImportedAt: Date?

    private var modelContainer: ModelContainer?
    private var pollTask: Task<Void, Never>?
    private var foregroundObserver: NSObjectProtocol?

    private let importer = MediaImporter()
    private let authorizer: PhotoLibraryAuthorizer

    init(authorizer: PhotoLibraryAuthorizer) {
        self.authorizer = authorizer
        if let stored = UserDefaults.standard.object(forKey: Self.lastScanKey) as? Date {
            self.lastScanAt = stored
        }
        super.init()
    }

    var recentImportCount: Int {
        // Count of imports within the last hour (used by HUD label).
        // Cheap approximation — totalImported is session-cumulative; we surface it directly.
        guard let last = lastImportedAt, Date().timeIntervalSince(last) < Self.recentImportWindow else {
            return 0
        }
        return totalImported
    }

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
    }

    func start() {
        guard !isEnabled else { return }
        guard authorizer.canRead else {
            Self.logger.info("PhotoScanCoordinator.start blocked: no photo library access")
            return
        }
        isEnabled = true
        ActivityLogger.shared.log(.telemetry, "[photo] scan coordinator started")

        // PHPhotoLibraryChangeObserver registration is deferred to Phase 3.

        installForegroundObserver()

        pollTask = Task { [weak self] in
            // Initial catch-up scan.
            await self?.scan()
            while let self, !Task.isCancelled, self.isEnabled {
                try? await Task.sleep(for: .seconds(Self.pollInterval))
                guard self.isEnabled else { return }
                await self.scan()
            }
        }
    }

    func stop() {
        guard isEnabled else { return }
        isEnabled = false
        pollTask?.cancel()
        pollTask = nil
        if let token = foregroundObserver {
            NotificationCenter.default.removeObserver(token)
            foregroundObserver = nil
        }
        ActivityLogger.shared.log(.telemetry, "[photo] scan coordinator stopped")
    }

    private func installForegroundObserver() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                await self.scan()
            }
        }
    }

    func scan() async {
        guard isEnabled, authorizer.canRead, let container = modelContainer else { return }

        let scanStart = Date()
        let since = (lastScanAt ?? Date().addingTimeInterval(-Self.initialLookback))
            .addingTimeInterval(-Self.overlapWindow)

        let assets = fetchRecentImageAssets(since: since)
        if assets.isEmpty {
            lastScanAt = scanStart
            UserDefaults.standard.set(scanStart, forKey: Self.lastScanKey)
            return
        }

        let context = ModelContext(container)
        var imported = 0
        var skipped = 0
        var nonMatch = 0

        for asset in assets {
            let result = await MetaGlassFilter.evaluateImage(asset: asset)
            switch result {
            case .confirmed(let meta):
                if await tryImport(asset: asset, metadata: meta, confidence: .confirmed, context: context) {
                    imported += 1
                } else {
                    skipped += 1
                }
            case .probable(let meta):
                if await tryImport(asset: asset, metadata: meta, confidence: .probable, context: context) {
                    imported += 1
                } else {
                    skipped += 1
                }
            case .nonMatch:
                nonMatch += 1
            }
        }

        if imported > 0 {
            totalImported += imported
            lastImportedAt = Date()
            // Trigger upload immediately.
            MediaUploadManager.shared.startProcessing(modelContainer: container)
        }

        lastScanAt = scanStart
        UserDefaults.standard.set(scanStart, forKey: Self.lastScanKey)

        ActivityLogger.shared.log(
            .telemetry,
            "[photo] scan complete since=\(Self.fmt(since)) checked=\(assets.count) imported=\(imported) deduped=\(skipped) nonMatch=\(nonMatch)"
        )
    }

    private func tryImport(
        asset: PHAsset,
        metadata: MetaGlassFilter.ExtractedMetadata,
        confidence: MediaMatchConfidence,
        context: ModelContext
    ) async -> Bool {
        do {
            return try await importer.importImage(
                asset: asset,
                metadata: metadata,
                confidence: confidence,
                modelContext: context
            ) != nil
        } catch {
            ActivityLogger.shared.log(.error, "[photo] import failed localId=\(asset.localIdentifier) error=\(error.localizedDescription)")
            return false
        }
    }

    private func fetchRecentImageAssets(since: Date) -> [PHAsset] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d AND creationDate >= %@", PHAssetMediaType.image.rawValue, since as NSDate)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetched = PHAsset.fetchAssets(with: options)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets
    }

    private static func fmt(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
