import Foundation
import ImageIO
import OSLog
import Photos

/// Identifies whether a PHAsset originates from Ray-Ban Meta Smart Glasses
/// using EXIF Make/Model + resolution multi-key matching.
struct MetaGlassFilter {
    private static let logger = Logger(subsystem: "com.recall", category: "MetaGlassFilter")

    /// EXIF Make value Meta AI app writes for Ray-Ban Meta photos.
    static let expectedMake = "Meta AI"

    /// EXIF Model substring (case-insensitive contains).
    static let expectedModelSubstring = "Ray-Ban Meta"

    /// Known native sensor resolutions (portrait + landscape).
    static let knownResolutions: Set<Resolution> = [
        Resolution(width: 3024, height: 4032),
        Resolution(width: 4032, height: 3024)
    ]

    struct Resolution: Hashable {
        let width: Int
        let height: Int
    }

    struct ExtractedMetadata {
        let make: String
        let model: String
        let pixelWidth: Int
        let pixelHeight: Int
        let uti: String
    }

    enum MatchResult {
        case confirmed(ExtractedMetadata)
        case probable(ExtractedMetadata)
        case nonMatch(reason: String)
    }

    /// Inspects an image asset and returns whether it matches Meta glasses.
    /// Image only — video path is intentionally rejected (Phase 1.5).
    static func evaluateImage(asset: PHAsset) async -> MatchResult {
        guard asset.mediaType == .image else {
            return .nonMatch(reason: "not an image (mediaType=\(asset.mediaType.rawValue))")
        }

        guard let metadata = await extractImageMetadata(asset: asset) else {
            return .nonMatch(reason: "metadata read failed")
        }

        let makeMatches = metadata.make.caseInsensitiveCompare(expectedMake) == .orderedSame
        let modelMatches = metadata.model.range(of: expectedModelSubstring, options: .caseInsensitive) != nil
        let resolutionMatches = knownResolutions.contains(
            Resolution(width: metadata.pixelWidth, height: metadata.pixelHeight)
        )

        if makeMatches && modelMatches && resolutionMatches {
            return .confirmed(metadata)
        }
        if makeMatches && modelMatches {
            return .probable(metadata)
        }
        return .nonMatch(reason: "make=\(metadata.make) model=\(metadata.model) res=\(metadata.pixelWidth)x\(metadata.pixelHeight)")
    }

    private static func extractImageMetadata(asset: PHAsset) async -> ExtractedMetadata? {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true

        let input: PHContentEditingInput? = await withCheckedContinuation { cont in
            asset.requestContentEditingInput(with: options) { input, _ in
                cont.resume(returning: input)
            }
        }

        guard let url = input?.fullSizeImageURL else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String) ?? ""
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? ""

        let pixelWidth = (props[kCGImagePropertyPixelWidth] as? Int) ?? asset.pixelWidth
        let pixelHeight = (props[kCGImagePropertyPixelHeight] as? Int) ?? asset.pixelHeight

        let uti: String
        if let typeId = CGImageSourceGetType(source) {
            uti = typeId as String
        } else {
            uti = (input?.uniformTypeIdentifier) ?? ""
        }

        return ExtractedMetadata(
            make: make,
            model: model,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            uti: uti
        )
    }
}
