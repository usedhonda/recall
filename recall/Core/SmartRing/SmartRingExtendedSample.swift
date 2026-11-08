import Foundation
import SmartRingKit

extension SmartRingSample {
    init(sensor: RingSensorRecord, command: RingReadCommand, peripheralID: UUID,
         firmware: String, timeZone: TimeZone) throws {
        try self.init(kind: "smart_ring.sensor.\(command.rawValue)", timestamp: sensor.timestamp,
                      bytes: sensor.rawBytes, peripheralID: peripheralID, firmware: firmware,
                      timeZone: timeZone, sensor: sensor, sleep: nil)
    }

    init(sleep: RingSleepRecord, peripheralID: UUID, firmware: String, timeZone: TimeZone) throws {
        try self.init(kind: "smart_ring.sleep_history", timestamp: sleep.timestamp,
                      bytes: sleep.rawBytes, peripheralID: peripheralID, firmware: firmware,
                      timeZone: timeZone, sensor: nil, sleep: sleep)
    }
}
