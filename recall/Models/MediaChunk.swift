import Foundation
import SwiftData

@Model
final class MediaChunk {
    @Attribute(.unique) var id: UUID
    var filePath: String
    var fileName: String
    var mediaTypeRaw: String
    var capturedAt: Date
    var importedAt: Date
    @Attribute(.unique) var photoLocalIdentifier: String
    var fileSize: Int64
    var pixelWidth: Int
    var pixelHeight: Int
    var uti: String
    var exifMake: String
    var exifModel: String
    var sourceRaw: String
    var matchConfidenceRaw: String
    var latitude: Double?
    var longitude: Double?

    // Video-specific fields (Phase 1.5; nil for images)
    var videoDurationSec: Double?
    var videoCodec: String?
    var videoFrameRate: Double?

    var uploadStatusRaw: String
    var uploadAttempts: Int
    var lastUploadAttempt: Date?
    var uploadedAt: Date?
    var createdAt: Date

    var mediaType: MediaType {
        get { MediaType(rawValue: mediaTypeRaw) ?? .image }
        set { mediaTypeRaw = newValue.rawValue }
    }

    var source: MediaImportSource {
        get { MediaImportSource(rawValue: sourceRaw) ?? .photos }
        set { sourceRaw = newValue.rawValue }
    }

    var matchConfidence: MediaMatchConfidence {
        get { MediaMatchConfidence(rawValue: matchConfidenceRaw) ?? .probable }
        set { matchConfidenceRaw = newValue.rawValue }
    }

    var uploadStatus: MediaUploadStatus {
        get { MediaUploadStatus(rawValue: uploadStatusRaw) ?? .pending }
        set { uploadStatusRaw = newValue.rawValue }
    }

    init(
        filePath: String,
        fileName: String,
        mediaType: MediaType,
        capturedAt: Date,
        photoLocalIdentifier: String,
        fileSize: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        uti: String,
        exifMake: String,
        exifModel: String,
        source: MediaImportSource,
        matchConfidence: MediaMatchConfidence,
        latitude: Double? = nil,
        longitude: Double? = nil,
        videoDurationSec: Double? = nil,
        videoCodec: String? = nil,
        videoFrameRate: Double? = nil
    ) {
        self.id = UUID()
        self.filePath = filePath
        self.fileName = fileName
        self.mediaTypeRaw = mediaType.rawValue
        self.capturedAt = capturedAt
        self.importedAt = Date()
        self.photoLocalIdentifier = photoLocalIdentifier
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.uti = uti
        self.exifMake = exifMake
        self.exifModel = exifModel
        self.sourceRaw = source.rawValue
        self.matchConfidenceRaw = matchConfidence.rawValue
        self.latitude = latitude
        self.longitude = longitude
        self.videoDurationSec = videoDurationSec
        self.videoCodec = videoCodec
        self.videoFrameRate = videoFrameRate
        self.uploadStatusRaw = MediaUploadStatus.pending.rawValue
        self.uploadAttempts = 0
        self.createdAt = Date()
    }
}

enum MediaType: String, Codable {
    case image
    case video
}

enum MediaImportSource: String, Codable {
    case photos
    case shareExtension = "share_extension"
    // Photo-library photo confirmed as Meta-glass capture. Sent as "glasses_dat"
    // so the VoiceLog/Gateway glasses gate routes it to Chi vision identically to
    // the DAT path — same delivery contract, no server-side change.
    case glasses = "glasses_dat"
}

enum MediaMatchConfidence: String, Codable {
    case confirmed
    case probable
}

enum MediaUploadStatus: String, Codable {
    case pending
    case uploading
    case uploaded
    case failed
}
