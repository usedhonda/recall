import Foundation
import Observation
import SwiftData
import OSLog

@Observable
@MainActor
final class UploadViewModel {
    private let logger = Logger(subsystem: "com.recall", category: "UploadVM")

    let uploadManager = UploadManager.shared

    var isUploading: Bool { uploadManager.isUploading }
    var pendingCount: Int { uploadManager.pendingCount }
    var uploadedCount: Int { uploadManager.uploadedCount }
    var failedCount: Int { uploadManager.failedCount }
    var uploadProgress: String { uploadManager.uploadProgress }
    var hasServerURL: Bool { !AppSettings.shared.uploadServerURL.isEmpty }

    func startUploading(modelContext: ModelContext) {
        uploadManager.startProcessing(modelContext: modelContext)
    }

    func stopUploading() {
        uploadManager.stopProcessing()
    }

    func retryFailed(modelContext: ModelContext) {
        uploadManager.retryFailed(modelContext: modelContext)
    }

    func refreshCounts(modelContext: ModelContext) {
        uploadManager.refreshCounts(modelContext: modelContext)
    }
}
