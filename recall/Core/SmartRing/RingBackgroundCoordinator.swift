import BackgroundTasks
import CoreBluetooth
import Foundation

/// Owns only OS wake/connection state. The SDK remains the sole history-command driver.
@MainActor
final class RingBackgroundCoordinator: NSObject, @preconcurrency CBCentralManagerDelegate {
    static let shared = RingBackgroundCoordinator()
    static let taskID = "com.example.recall.ring-sync"
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var lastWake: Date?

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskID, using: nil) { task in
            Task { @MainActor in
                self.schedule()
                task.expirationHandler = { Task { @MainActor in SmartRingManager.shared.cancelSync() } }
                let success = await SmartRingManager.shared.backgroundSync()
                task.setTaskCompleted(success: success)
            }
        }
        start()
    }

    func start() {
        guard AppSettings.shared.smartRingEnabled, AppSettings.shared.smartRingPeripheralID != nil,
              CBManager.authorization == .allowedAlways else { return }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "recall.smart-ring.central"])
        }
        schedule()
    }

    func schedule() {
        guard AppSettings.shared.smartRingEnabled, AppSettings.shared.smartRingPeripheralID != nil,
              !AppSettings.shared.smartRingClockTimeZone.isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date().addingTimeInterval(900)
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        do { try BGTaskScheduler.shared.submit(request) }
        catch { ActivityLogger.shared.log(.health, "Ring background request unavailable; foreground sync remains enabled") }
    }

    func stop() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, AppSettings.shared.smartRingEnabled,
              let id = AppSettings.shared.smartRingPeripheralID,
              let known = central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        peripheral = known
        if known.state == .connected { wake() } else { central.connect(known) }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard AppSettings.shared.smartRingEnabled,
              let id = AppSettings.shared.smartRingPeripheralID else { return }
        peripheral = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first { $0.identifier == id }
        if let peripheral {
            if peripheral.state == .connected { wake() } else { central.connect(peripheral) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) { wake() }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard AppSettings.shared.smartRingEnabled else { return }
        central.connect(peripheral)
    }

    private func wake() {
        guard AppSettings.shared.smartRingEnabled,
              lastWake.map({ Date().timeIntervalSince($0) >= 900 }) ?? true else { return }
        lastWake = Date()
        Task { @MainActor in
            ActivityLogger.shared.log(.health, "Ring Bluetooth wake; background acquisition requested")
            _ = await SmartRingManager.shared.backgroundSync()
        }
    }
}
