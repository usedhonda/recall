import Foundation
import Observation
import SmartRingKit

/// An opt-in foreground stream. Never depends on Audio or HealthKit authorization/toggles.
@MainActor
@Observable
final class SmartRingManager {
    static let shared = SmartRingManager()
    private(set) var isEnabled = AppSettings.shared.smartRingEnabled
    private(set) var devices: [RingPeripheral] = []
    private(set) var isBusy = false
    private(set) var status = "Direct ring sync is off."
    private(set) var lastSyncAt: Date?
    private(set) var storedCount = 0
    private(set) var pendingCount = 0
    private(set) var selectedID = AppSettings.shared.smartRingPeripheralID
    private(set) var selectedName = AppSettings.shared.smartRingName
    private(set) var clockTimeZone = AppSettings.shared.smartRingClockTimeZone
    private var client: RingClient?
    private var store: SmartRingStore?
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var isForeground = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        AppSettings.shared.smartRingEnabled = enabled
        if enabled { resume() }
        else {
            pause()
            status = "Direct ring sync is off."
        }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if active { resume() } else { pause() }
    }

    func select(_ device: RingPeripheral) {
        guard !isBusy else { return }
        selectedID = device.id
        selectedName = device.name ?? "Selected ring"
        AppSettings.shared.smartRingPeripheralID = device.id
        AppSettings.shared.smartRingName = selectedName
        status = "Ring selected. Confirm its clock time zone, then sync."
    }

    func setClockTimeZone(_ identifier: String) {
        guard !isBusy, TimeZone(identifier: identifier) != nil else { return }
        clockTimeZone = identifier
        AppSettings.shared.smartRingClockTimeZone = identifier
    }

    func scan() {
        guard isEnabled, isForeground, !isBusy else { return }
        run {
            let client = RingClient()
            self.client = client
            defer { client.disconnect(); self.client = nil }
            self.devices = try await client.discover()
            self.status = "Found \(self.devices.count) candidate(s). Select your ring."
        }
    }

    func sync() {
        guard isEnabled, isForeground, !isBusy, let id = selectedID,
              let timeZone = TimeZone(identifier: clockTimeZone) else { return }
        run {
            let store = try self.archive()
            var failure: Error?
            do { try await self.capture(id: id, timeZone: timeZone, store: store) }
            catch { failure = error }
            try Task.checkCancellation()
            // Admission failures do not prevent capture. A failed radio read also does
            // not prevent previously stored observations from entering the outbox.
            do { try await self.queuePending(store) }
            catch { if failure == nil { failure = error } }
            let counts = await store.counts()
            self.storedCount = counts.stored
            self.pendingCount = counts.pending
            self.status = "Stored \(counts.stored) ring records; \(counts.pending) pending, including \(counts.held) held by the history retention limit."
            if let failure { self.status += " \(failure.localizedDescription)" }
            ActivityLogger.shared.log(.health, "Ring sync: \(counts.stored) stored, \(counts.pending) pending local admission, error=\(failure != nil)")
        }
    }

    private func capture(id: UUID, timeZone: TimeZone, store: SmartRingStore) async throws {
        let client = RingClient()
        self.client = client
        defer { client.disconnect(); self.client = nil }
        _ = try await client.discover(duration: 2)
        try await client.connect(to: id)
        let info = try await client.readInfo()
        let records = try await client.readHRVHistory()
        try Task.checkCancellation()
        let samples = try records.map {
            try SmartRingSample(record: $0, peripheralID: id, firmware: info.firmware, timeZone: timeZone)
        }
        try await store.merge(samples, capturedAt: Date())
        lastSyncAt = Date()
    }

    private func archive() throws -> SmartRingStore {
        if let store { return store }
        let created = try SmartRingStore(url: SmartRingStore.defaultURL)
        store = created
        return created
    }

    private func queuePending(_ store: SmartRingStore) async throws {
        guard HubDeliveryService.shared.isEnabled(.healthSamples) else { return }
        try await store.drain { payload, identity, occurredAt in
            try Task.checkCancellation()
            _ = try await HubDeliveryService.shared.admit(
                route: .healthSamples, observationID: identity, occurredAt: occurredAt,
                timeBasis: "ring_captured_at", sourcePayloadJSON: payload
            )
        }
    }

    private func resume() {
        guard isEnabled, isForeground else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
        }
        if selectedID != nil, !clockTimeZone.isEmpty { sync() }
        else { status = "Select a ring and its clock time zone to enable direct reads." }
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        operation?.cancel()
        client?.disconnect()
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        status = "Working…"
        operation = Task { @MainActor in
            defer { self.isBusy = false; self.operation = nil }
            do { try await action() }
            catch {
                if !Task.isCancelled { self.status = error.localizedDescription }
                ActivityLogger.shared.log(.health, "Ring sync did not complete; saved records remain pending")
            }
        }
    }
}
