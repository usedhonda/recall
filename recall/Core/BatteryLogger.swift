import UIKit

/// Writes the battery level into the activity log so a power change can be judged in
/// percent per hour instead of by impression. Nothing reads it back and it never appears
/// on screen: it exists to make the next before/after comparison a measurement.
///
/// It rides the location heartbeat tick rather than owning a timer, because a timer of
/// its own would spend some of what it is trying to measure. That means the trail stops
/// when the location stream is off — it observes, it never gates.
@MainActor
enum BatteryLogger {
    private static var lastLevel: Int?
    private static var lastState: UIDevice.BatteryState?

    static func note() {
        let device = UIDevice.current
        guard device.isBatteryMonitoringEnabled else {
            // iOS needs a moment before it answers; the next tick reads a real level.
            device.isBatteryMonitoringEnabled = true
            return
        }

        let raw = device.batteryLevel
        guard raw >= 0 else { return }
        let level = Int((raw * 100).rounded())
        let state = device.batteryState
        guard level != lastLevel || state != lastState else { return }
        lastLevel = level
        lastState = state

        ActivityLogger.shared.log(.state, "Battery: \(level)% \(name(of: state))")
    }

    private static func name(of state: UIDevice.BatteryState) -> String {
        switch state {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
    }
}
