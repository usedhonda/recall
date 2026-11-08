import Foundation
import SmartRingKit

/// Durable acquisition evidence. Separate from the already admitted HRV archive.
@MainActor
final class SmartRingCaptureArchive {
    private let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("smart-ring-captures", isDirectory: true)
    }

    func count() throws -> Int { try FileManager.default.contentsOfDirectory(atPath: root.path).count }

    func saveContext(_ snapshot: RingHistorySnapshot, timeZone: TimeZone, existingObservationCount: Int) throws {
        struct Context: Encodable {
            let info: RingInfo
            let deviceClock: RingTimestamp?
            let clockFailure: String?
            let clockTimeZone: String
            let capturedAt: Date
            let captureKeys: [String]
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let keys = try snapshot.histories.map { try key($0) }
        let data = try encoder.encode(Context(info: snapshot.info, deviceClock: snapshot.deviceClock,
            clockFailure: snapshot.clockFailure, clockTimeZone: timeZone.identifier,
            capturedAt: snapshot.capturedAt, captureKeys: keys))
        let identity = keys.joined() + "|" + snapshot.info.firmware + "|" + timeZone.identifier
        var url = root.appendingPathComponent("context-" + SmartRingSample.hash(Data(identity.utf8)) + ".json")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        guard try count() + existingObservationCount < 10_000 else { throw SmartRingStore.Failure.archiveFull }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
    }

    private func key(_ capture: RingHistoryCapture) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var body = try encoder.encode(capture.raw)
        body.append(Data(capture.peripheralID.uuidString.utf8))
        body.append(capture.transferComplete ? 1 : 0)
        return SmartRingSample.hash(body)
    }

    func save(_ capture: RingHistoryCapture, capturedAt: Date, timeZone: TimeZone,
              existingObservationCount: Int) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let identity = try key(capture)
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

    func saveBackground(raw: RingRawHistory, info: RingInfo, peripheralID: UUID,
                        complete: Bool, capturedAt: Date, timeZone: TimeZone,
                        existingObservationCount: Int, unexpected: [[UInt8]]) throws {
        struct BackgroundCapture: Codable {
            let raw: RingRawHistory
            let info: RingInfo
            let peripheralID: UUID
            let transferComplete: Bool
            let capturedAt: Date
            let clockTimeZone: String
            let unexpectedNotifications: [[UInt8]]
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var identity = try encoder.encode(raw)
        identity.append(Data((peripheralID.uuidString + info.firmware + timeZone.identifier).utf8))
        identity.append(complete ? 1 : 0)
        identity.append(try encoder.encode(unexpected))
        var url = root.appendingPathComponent("background-" + SmartRingSample.hash(identity) + ".json")
        guard !fm.fileExists(atPath: url.path) else { return }
        guard try count() + existingObservationCount < 10_000 else { throw SmartRingStore.Failure.archiveFull }
        try encoder.encode(BackgroundCapture(raw: raw, info: info, peripheralID: peripheralID,
            transferComplete: complete, capturedAt: capturedAt, clockTimeZone: timeZone.identifier,
            unexpectedNotifications: unexpected))
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try url.setResourceValues(flags)
    }
}
