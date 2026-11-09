import CryptoKit
import Foundation
import SmartRingKit

/// A ring observation, not an HKSample or a HealthKit SDNN measurement.
/// Common health-samples keys remain readable; the namespace and ring payload identify
/// the direct source. Never merge these with HealthKit by timestamp alone.
struct SmartRingSample: Codable, Equatable {
    let uuid: String
    let type: String
    let start: Date
    let end: Date
    let source: String
    let sourceVersion: String
    let deviceModel: String
    let ring: Payload
    var sensor: RingSensorRecord? = nil
    var sleep: RingSleepRecord? = nil
    var capturedAt: Date? = nil
    var availableAt: Date? = nil

    struct Payload: Codable, Equatable {
        let deviceID: String
        let firmware: String
        let clockTimeZone: String
        let deviceTime: RingTimestamp
        let hrvRaw: UInt8?
        let heartRateBPM: UInt8?
        let stressRaw: UInt8?
        let rawBytes: [UInt8]
    }

    init(record: RingHRVRecord, peripheralID: UUID, firmware: String, timeZone: TimeZone) throws {
        guard let date = record.timestamp.date(in: timeZone) else {
            throw RingError.invalidPacket("ring clock cannot be interpreted in the selected time zone")
        }
        // Exclude transfer sequence bytes 1-2: a repeated download may reorder records.
        let device = Self.hash(Data(peripheralID.uuidString.lowercased().utf8))
        var identity = Data("ring-v1|\(device)|\(timeZone.identifier)|".utf8)
        identity.append(contentsOf: record.rawBytes.dropFirst(3))
        uuid = "ring-" + Self.hash(identity)
        type = "smart_ring.hrv_history"
        start = date
        end = date
        source = "SmartRingKit"
        sourceVersion = "0.7.1"
        deviceModel = "FFF0 ring"
        ring = Payload(deviceID: device, firmware: firmware, clockTimeZone: timeZone.identifier,
                       deviceTime: record.timestamp, hrvRaw: record.hrvRaw,
                       heartRateBPM: record.heartRateBPM, stressRaw: record.stressRaw,
                       rawBytes: record.rawBytes)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    init(kind: String, timestamp: RingTimestamp, bytes: [UInt8], peripheralID: UUID,
         firmware: String, timeZone: TimeZone, sensor: RingSensorRecord?, sleep: RingSleepRecord?) throws {
        guard let date = timestamp.date(in: timeZone) else { throw RingError.invalidPacket("invalid ring clock") }
        let device = Self.hash(Data(peripheralID.uuidString.lowercased().utf8))
        var identity = Data("ring-v2|\(device)|\(timeZone.identifier)|\(kind)|".utf8)
        identity.append(contentsOf: bytes.dropFirst(sensor?.dateOnly == true ? 2 : 3))
        uuid = "ring-" + Self.hash(identity)
        type = kind
        start = date
        end = sleep.map { date.addingTimeInterval(Double($0.categoryValues.count * $0.sampleIntervalMinutes) * 60) } ?? date
        source = "SmartRingKit"
        sourceVersion = "0.7.1"
        deviceModel = "FFF0 ring"
        ring = Payload(deviceID: device, firmware: firmware, clockTimeZone: timeZone.identifier,
                       deviceTime: timestamp, hrvRaw: nil, heartRateBPM: nil, stressRaw: nil, rawBytes: bytes)
        self.sensor = sensor
        self.sleep = sleep
    }
}
