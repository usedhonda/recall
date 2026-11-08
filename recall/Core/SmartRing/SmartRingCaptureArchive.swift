import Foundation
import SmartRingKit

/// Durable acquisition evidence. Separate from the already admitted HRV archive.
@MainActor
final class SmartRingCaptureArchive {
    private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("smart-ring-captures", isDirectory: true)

    func count() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: root.path).count }

    func save(_ capture: RingHistoryCapture, capturedAt: Date, timeZone: TimeZone,
              existingObservationCount: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var body = try encoder.encode(capture.raw)
        body.append(Data(capture.peripheralID.uuidString.utf8))
        let identity = SmartRingSample.hash(body)
        var file = root.appendingPathComponent(identity + ".json")
        guard !fm.fileExists(atPath: file.path) else { return }
        guard try fm.contentsOfDirectory(atPath: root.path).count + existingObservationCount < 10_000 else {
            throw SmartRingStore.Failure.archiveFull
        }
        let value = Stored(capture: capture, capturedAt: capturedAt, clockTimeZone: timeZone.identifier)
        try JSONEncoder().encode(value).write(to: file,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try file.setResourceValues(flags)
    }

    private struct Stored: Codable {
        let capture: RingHistoryCapture
        let capturedAt: Date
        let clockTimeZone: String
    }
}
