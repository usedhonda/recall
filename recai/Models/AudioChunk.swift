import Foundation
import SwiftData

@Model
final class AudioChunk {
    @Attribute(.unique) var id: UUID
    var filePath: String
    var fileName: String
    var startedAt: Date
    var duration: TimeInterval
    var fileSize: Int64
    var uploadStatusRaw: String
    var uploadAttempts: Int
    var lastUploadAttempt: Date?
    var uploadedAt: Date?
    var createdAt: Date

    var uploadStatus: UploadStatus {
        get { UploadStatus(rawValue: uploadStatusRaw) ?? .pending }
        set { uploadStatusRaw = newValue.rawValue }
    }

    init(
        filePath: String,
        fileName: String,
        startedAt: Date,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0
    ) {
        self.id = UUID()
        self.filePath = filePath
        self.fileName = fileName
        self.startedAt = startedAt
        self.duration = duration
        self.fileSize = fileSize
        self.uploadStatusRaw = UploadStatus.pending.rawValue
        self.uploadAttempts = 0
        self.createdAt = Date()
    }

    enum UploadStatus: String, Codable {
        case pending
        case uploading
        case uploaded
        case failed
    }
}
