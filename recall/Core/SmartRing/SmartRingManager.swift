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
    private(set) var healthSamples: [SmartRingSample] = []
    private(set) var researchInputs: RingStressFeatureSet?
    private(set) var fatigueEstimate: RingFatigueEstimate?
    private(set) var fatigueAnalysisStatus = "Experimental fatigue estimation is off."
    private var firmware = ""
    var fatigueSnapshot: SmartRingFatigueEstimate? {
        guard isEnabled, let estimate = fatigueEstimate, let id = selectedID,
              RingDeviceProfiles.matching(deviceID: AppSettings.shared.smartRingDeviceModelID, firmware: firmware) != nil else { return nil }
        return SmartRingFatigueEstimate(sourceDeviceID: SmartRingSample.hash(Data(id.uuidString.lowercased().utf8)),
            firmware: firmware, clockTimeZone: clockTimeZone, estimate: estimate)
    }
    private(set) var selectedID = AppSettings.shared.smartRingPeripheralID
    private(set) var selectedName = AppSettings.shared.smartRingName
    private(set) var clockTimeZone = AppSettings.shared.smartRingClockTimeZone
    private var client: RingClient?
    private var store: SmartRingStore?
    private let captureArchive = SmartRingCaptureArchive()
    private var operation: Task<Void, Never>?
    private var timer: Timer?
    private var isForeground = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        AppSettings.shared.smartRingEnabled = enabled
        if enabled { RingBackgroundCoordinator.shared.start(); resume() }
        else {
            pause()
            status = "Direct ring sync is off."
        }
    }

    func setForeground(_ active: Bool) {
        isForeground = active
        if active { RingBackgroundCoordinator.shared.start() }
        if active { resume() } else {
            timer?.invalidate(); timer = nil
            RingBackgroundCoordinator.shared.schedule()
        }
    }

    func select(_ device: RingPeripheral) {
        guard !isBusy else { return }
        selectedID = device.id
        firmware = ""; researchInputs = nil; fatigueEstimate = nil
        selectedName = device.name ?? "Selected ring"
        AppSettings.shared.smartRingPeripheralID = device.id
        AppSettings.shared.smartRingName = selectedName
        RingBackgroundCoordinator.shared.start()
        status = "Ring selected. Confirm its clock time zone, then sync."
    }

    func setClockTimeZone(_ identifier: String) {
        guard !isBusy, TimeZone(identifier: identifier) != nil else { return }
        clockTimeZone = identifier
        researchInputs = nil; fatigueEstimate = nil
        fatigueAnalysisStatus = "Sync to analyze this clock interpretation."
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

    func sync(background: Bool = false) {
        guard isEnabled, (isForeground || background), !isBusy, let id = selectedID,
              let timeZone = TimeZone(identifier: clockTimeZone) else { return }
        run {
            let store = try self.archive()
            var failure: Error?
            do {
                if background { try await self.captureBackground(id: id, timeZone: timeZone, store: store) }
                else { try await self.capture(id: id, timeZone: timeZone, store: store) }
            }
            catch { failure = error }
            try Task.checkCancellation()
            // Admission failures do not prevent capture. A failed radio read also does
            // not prevent previously stored observations from entering the outbox.
            do { try await self.queuePending(store) }
            catch { if failure == nil { failure = error } }
            self.healthSamples = await store.samplesForHealthSnapshot()
            self.refreshResearch()
            do { try await self.queueHealthSnapshot() }
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
        // Broader foreground backfill also recovers corrections before a resume anchor.
        let commands: [RingReadCommand] = [.spotHeartRateHistory, .hrvHistory, .sleepHistory,
            .temperatureHistory, .oxygenHistory, .dailyActivityHistory, .activityHistory,
            .manualOxygenHistory, .exerciseHistory, .heartRateHistory]
        var failure: Error?
        for command in commands {
            try Task.checkCancellation()
            do { try await captureCategory(command, id: id, timeZone: timeZone, store: store, incremental: false) }
            catch {
                if Task.isCancelled { throw error }
                if !(error is RingError) { throw error }
                if failure == nil { failure = error }
                if let ringError = error as? RingError, case .conflictingHistoryResponse = ringError { break }
            }
        }
        if let failure { throw failure }
        lastSyncAt = Date()
    }

    private func mergeDecoded(_ histories: [(RingReadCommand, RingDecodedHistory)], id: UUID,
                              firmware: String, timeZone: TimeZone, capturedAt: Date,
                              store: SmartRingStore) async throws {
        let records = histories.flatMap { $0.1.hrv }
        var samples = try records.map {
            try SmartRingSample(record: $0, peripheralID: id, firmware: firmware, timeZone: timeZone)
        }
        for (command, decoded) in histories {
            let hasGap = decoded.integrity.map {
                $0.missingSequenceValues > 0 || $0.outOfOrderTransitions > 0
            } ?? false
            if !hasGap {
                samples += try decoded.sensors.map {
                    try SmartRingSample(sensor: $0, command: command, peripheralID: id,
                                        firmware: firmware, timeZone: timeZone)
                }
            }
            samples += try decoded.sleep.map {
                try SmartRingSample(sleep: $0, peripheralID: id, firmware: firmware, timeZone: timeZone)
            }
        }
        // Full old history remains in protected captures, not new upload identities.
        let eligible = await store.inRetentionWindow(samples)
        try await store.merge(eligible, capturedAt: capturedAt, reservedSlots: captureArchive.count(), availableAt: capturedAt)
    }

    private func captureBackground(id: UUID, timeZone: TimeZone, store: SmartRingStore) async throws {
        let backfill: [RingReadCommand] = [.sleepHistory, .oxygenHistory, .temperatureHistory,
            .dailyActivityHistory, .activityHistory, .manualOxygenHistory, .exerciseHistory, .heartRateHistory]
        let position = UserDefaults.standard.integer(forKey: "smartRing.backgroundBackfillIndex") % backfill.count
        // Persist each category before moving on; OS expiry can cancel between any two reads.
        for command in [RingReadCommand.spotHeartRateHistory, .hrvHistory, backfill[position]] {
            try Task.checkCancellation()
            try await captureCategory(command, id: id, timeZone: timeZone, store: store, incremental: true)
            if command == backfill[position] {
                UserDefaults.standard.set((position + 1) % backfill.count, forKey: "smartRing.backgroundBackfillIndex")
            }
        }
        lastSyncAt = Date()
    }

    private func captureCategory(_ command: RingReadCommand, id: UUID, timeZone: TimeZone,
                                 store: SmartRingStore, incremental: Bool) async throws {
        let startedAt = Date()
        do {
            try await readCategory(command, id: id, timeZone: timeZone, store: store, incremental: incremental)
        } catch {
            ActivityLogger.shared.log(.health, "Ring category \(command.rawValue) failed: \(error.localizedDescription)")
            try captureArchive.saveFailure(command: command.rawValue, peripheralID: id, timeZone: timeZone,
                startedAt: startedAt, error: error, existingObservationCount: await store.counts().stored)
            throw error
        }
    }

    private func readCategory(_ command: RingReadCommand, id: UUID, timeZone: TimeZone,
                              store: SmartRingStore, incremental: Bool) async throws {
        let client = RingClient(); self.client = client
        defer { client.disconnect(); self.client = nil }
        _ = try await client.discover(duration: 1)
        try await client.connect(to: id)
        let info = try await client.readInfo()
        firmware = info.firmware
        var deviceClock: RingTimestamp?
        var clockFailure: String?
        do { deviceClock = try await client.readDeviceClock() }
        catch {
            clockFailure = error.localizedDescription
            try Task.checkCancellation()
            try await client.connect(to: id)
        }
        let device = SmartRingSample.hash(Data(id.uuidString.lowercased().utf8))
        let hint = incremental ? await store.resumeHint(command: command.rawValue, deviceID: device,
            firmware: info.firmware, timeZone: timeZone.identifier) : nil
        let startedAt = Date()
        var packets: [[UInt8]] = []
        var unexpected: [[UInt8]] = []
        var unexpectedBytes = 0
        var expectedBytes = 0
        var byteLimitExceeded = false
        var conflictingCommand: UInt8?
        var complete = false
        var failure: Error?
        do {
            _ = try await client.readRawHistory(command, resumingFrom: hint, timeout: 120,
                onNotification: {
                    guard $0.count <= 2_000_000 - expectedBytes else {
                        byteLimitExceeded = true; client.disconnect(); return
                    }
                    packets.append([UInt8]($0)); expectedBytes += $0.count
                }, onUnexpectedNotification: {
                    if let byte = $0.first, RingReadCommand.historyCommands.contains(where: { $0.rawValue == byte }) {
                        conflictingCommand = byte
                    }
                    guard $0.count <= 2_000_000 - unexpectedBytes else {
                        byteLimitExceeded = true; client.disconnect(); return
                    }
                    unexpected.append([UInt8]($0)); unexpectedBytes += $0.count
                })
            complete = true
        } catch { failure = error }
        if byteLimitExceeded { failure = RingError.invalidPacket("Capture byte limit exceeded; partial data preserved") }
        if let byte = conflictingCommand {
            failure = RingError.conflictingHistoryResponse(expected: command.rawValue, received: byte)
        }
        let capturedAt = Date()
        let raw = RingRawHistory(command: command.rawValue, notifications: packets)
        try captureArchive.saveBackground(raw: raw, info: info, peripheralID: id, complete: complete,
            capturedAt: capturedAt, timeZone: timeZone, existingObservationCount: await store.counts().stored,
            unexpected: unexpected, resumeHint: hint, deviceClock: deviceClock,
            clockFailure: clockFailure, failure: failure?.localizedDescription, startedAt: startedAt,
            acquisitionMode: incremental ? "background" : "foreground")
        if let failure { throw failure }
        try Task.checkCancellation()
        try await mergeDecoded([(command, RingHistoryCodec.decode(raw))], id: id, firmware: info.firmware,
            timeZone: timeZone, capturedAt: capturedAt, store: store)
        ActivityLogger.shared.log(.health, "Ring category \(command.rawValue) completed; persisted before next read; incremental=\(hint != nil)")
    }

    func setFatigueMethod(_ method: String) {
        guard method.isEmpty || RingFatigueCorrection(rawValue: method) != nil else { return }
        AppSettings.shared.smartRingFatigueMethod = method
        refreshResearch()
    }

    private func refreshResearch() {
        guard let id = selectedID, let zone = TimeZone(identifier: clockTimeZone),
              RingDeviceProfiles.matching(deviceID: AppSettings.shared.smartRingDeviceModelID, firmware: firmware) != nil else {
            researchInputs = nil; fatigueEstimate = nil
            fatigueAnalysisStatus = "Read a verified device profile before analysis."
            return
        }
        do {
            let result = try SmartRingResearch.evaluate(healthSamples,
                deviceID: SmartRingSample.hash(Data(id.uuidString.lowercased().utf8)), firmware: firmware,
                timeZone: zone, method: RingFatigueCorrection(rawValue: AppSettings.shared.smartRingFatigueMethod), at: Date())
            researchInputs = result.inputs; fatigueEstimate = result.estimate
            fatigueAnalysisStatus = result.estimate.map { "\($0.status): \($0.reason ?? "experimental_unvalidated")" }
                ?? "Experimental fatigue estimation is off."
        } catch {
            researchInputs = nil; fatigueEstimate = nil
            fatigueAnalysisStatus = "Research inputs unavailable: \(error.localizedDescription)"
        }
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

    private func queueHealthSnapshot() async throws {
        try Task.checkCancellation()
        guard isEnabled, !healthSamples.isEmpty, HubDeliveryService.shared.isEnabled(.healthSnapshot) else { return }
        let health = TelemetryService.shared.healthManager
        var payload = HealthDataIntegrator.combine(
            healthKit: health.isEnabled ? health.latestHealthKitPayload : nil,
            ring: healthSamples, collectedAt: Date(), deviceModelID: AppSettings.shared.smartRingDeviceModelID)
        payload.nativeFatigueEstimate = fatigueSnapshot
        _ = try await HubTelemetryAdmission.admit(route: .healthSnapshot,
            observationID: payload.deliveryID.uuidString, occurredAt: payload.collectedAt, payload: payload)
    }

    private func pause() {
        timer?.invalidate()
        timer = nil
        operation?.cancel()
        client?.disconnect()
        RingBackgroundCoordinator.shared.stop()
    }

    func backgroundSync() async -> Bool {
        guard isEnabled, !isBusy, selectedID != nil, !clockTimeZone.isEmpty else { return false }
        let before = lastSyncAt
        sync(background: true)
        await operation?.value
        return lastSyncAt != nil && lastSyncAt != before
    }

    func cancelSync() { operation?.cancel(); client?.disconnect() }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        isBusy = true
        status = "Working…"
        operation = Task { @MainActor in
            defer { self.isBusy = false; self.operation = nil }
            do { try await action() }
            catch {
                self.status = Task.isCancelled ? "Sync interrupted; saved progress retained." : error.localizedDescription
                ActivityLogger.shared.log(.health, "Ring sync did not complete; saved records remain pending")
            }
        }
    }
}
