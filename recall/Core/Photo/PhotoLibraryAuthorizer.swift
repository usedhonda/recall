import Foundation
import Observation
import OSLog
import Photos

@Observable
@MainActor
final class PhotoLibraryAuthorizer {
    private static let logger = Logger(subsystem: "com.recall", category: "PhotoLibraryAuthorizer")

    private(set) var status: PHAuthorizationStatus = .notDetermined

    init() {
        refresh()
    }

    var hasFullAccess: Bool {
        status == .authorized
    }

    var hasLimitedAccess: Bool {
        status == .limited
    }

    var canRead: Bool {
        status == .authorized || status == .limited
    }

    func refresh() {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    @discardableResult
    func requestReadWrite() async -> PHAuthorizationStatus {
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
        status = granted
        Self.logger.info("PhotoLibrary auth status: \(granted.rawValue)")
        ActivityLogger.shared.log(.telemetry, "PhotoLibrary auth status: \(Self.statusName(granted))")
        return granted
    }

    static func statusName(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .limited: return "limited"
        @unknown default: return "unknown"
        }
    }
}
