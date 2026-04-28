import Foundation
import HealthKit
import Observation
import UIKit

/// Manages HealthKit data queries and periodic summary sends
@MainActor
@Observable
final class HealthKitManager {
    private static let maxErrorHistoryCount = 5
    private static let errorDedupWindow: TimeInterval = 10

    // MARK: - Published State

    private(set) var lastSendResult: HealthSendResult = .none
    private(set) var lastSentTime: Date?
    private(set) var lastAcceptedAt: Date?
    private(set) var lastSummary: HealthSummary?
    private(set) var isAuthorized = false
    private(set) var errorHistory: [HealthNetworkError] = []
    private(set) var suppressedDuplicateErrors = 0
    private(set) var totalQueries = 0
    private(set) var totalSuccessfulSends = 0
    private(set) var totalSendErrors = 0
    private(set) var totalAuthorizationFailures = 0
    private(set) var lastQueryAt: Date?
    private(set) var lastErrorAt: Date?
    private(set) var lastErrorMessage: String?

    // MARK: - Settings

    var isEnabled: Bool = false {
        didSet {
            AppSettings.shared.healthEnabled = isEnabled
            guard !isRestoring else { return }
            if isEnabled {
                ActivityLogger.shared.log(.health, "Health enabled")
                startTimer()
                // Immediate first query
                Task {
                    await queryAndSend()
                }
            } else {
                ActivityLogger.shared.log(.health, "Health disabled")
                stopTimer()
                teardownObserverQueries()
            }
        }
    }

    // MARK: - Private Properties

    private let healthStore = HKHealthStore()
    private var timer: Timer?
    private var observerQueries: [HKObserverQuery] = []
    private var isRestoring = false

    // Observer wake tracking — key = HK identifier raw value (e.g. "HKQuantityTypeIdentifierHeartRate")
    private var observerWakeCounts: [String: Int] = [:]
    private var observerWakeLogTimer: Timer?

    // Debounce / coalesce HKObserverQuery wakes. Background-delivery is now
    // registered for low-frequency metrics too, and a single body-composition
    // app session can write multiple related samples in quick succession (mass
    // + body fat + lean + BMI). Without coalescing each one would trigger a
    // full queryAndSend cycle.
    private var lastObserverSendAt: Date = .distantPast
    private let observerDebounceInterval: TimeInterval = 60
    private var pendingObserverSendTask: Task<Void, Never>?
    private var sendInterval: TimeInterval {
        AppSettings.shared.telemetrySendInterval  // same as Location (default 60s)
    }

    // MARK: - Initialization

    init() {}

    /// Restore enabled state from AppSettings without triggering side effects
    /// (timer start / immediate query). Caller is responsible for starting the timer
    /// after authorization completes.
    func restoreSettings() {
        isRestoring = true
        let savedEnabled = AppSettings.shared.healthEnabled
        if savedEnabled && HKHealthStore.isHealthDataAvailable() {
            isEnabled = true
        }
        isRestoring = false
    }

    // MARK: - Authorization

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = []

        let quantityTypes: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .heartRate,
            .restingHeartRate,
            .heartRateVariabilitySDNN,
            .activeEnergyBurned,
            .basalEnergyBurned,
            .distanceWalkingRunning,
            .flightsClimbed,
            .oxygenSaturation,
            .respiratoryRate,
            .bodyMass,
            .bodyFatPercentage,
            .leanBodyMass,
            .bodyMassIndex,
            .bodyTemperature,
            .appleSleepingWristTemperature,
        ]

        for id in quantityTypes {
            if let type = HKQuantityType.quantityType(forIdentifier: id) {
                types.insert(type)
            }
        }

        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            types.insert(sleepType)
        }

        types.insert(HKWorkoutType.workoutType())

        return types
    }

    func requestAuthorization() async -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            lastSendResult = .error("HealthKit not available")
            totalAuthorizationFailures += 1
            recordHealthError("HealthKit not available")
            return false
        }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            isAuthorized = true
            // Re-register bg delivery after auth — iOS may have silently disabled it
            // during long background kills or HealthKit permission state transitions.
            setupBackgroundDelivery()
            return true
        } catch {
            let message = "Authorization failed: \(error.localizedDescription)"
            lastSendResult = .error(message)
            totalAuthorizationFailures += 1
            recordHealthError(message)
            isAuthorized = false
            return false
        }
    }

    // MARK: - Background Delivery

    /// Set up HKObserverQuery + enableBackgroundDelivery for key health types.
    /// iOS will wake the app when new samples arrive, even if the process was killed.
    /// Safe to call multiple times — tears down existing observers and disables prior
    /// bg delivery before re-registering. Call from AppDelegate.didFinishLaunchingWithOptions
    /// and again after authorization completes to recover from long-term iOS delivery failures.
    func setupBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

        // Tear down existing observers to prevent duplicate wake callbacks
        if !observerQueries.isEmpty {
            teardownObserverQueries()
            healthStore.disableAllBackgroundDelivery { success, error in
                if let error {
                    ActivityLogger.shared.logFromBackground(.health, "disableAllBackgroundDelivery error: \(error.localizedDescription)")
                }
            }
        }

        // High-frequency metrics: already wake recall on every new sample
        // (heart rate / step writes) — these drive the regular telemetry beat.
        // Low-frequency metrics: weights, resting HR, body comp, temperatures,
        // workouts. Without observers these only got picked up on app launch
        // or as a piggyback on location/HR wake, which could leave a freshly
        // entered weight invisible until next foreground.
        let monitoredTypes: [HKQuantityTypeIdentifier] = [
            // High-frequency
            .stepCount,
            .heartRate,
            .heartRateVariabilitySDNN,
            .oxygenSaturation,
            // Low-frequency (added per Cdx audit; debounce coalesces bursts)
            .restingHeartRate,
            .respiratoryRate,
            .bodyMass,
            .bodyFatPercentage,
            .leanBodyMass,
            .bodyMassIndex,
            .bodyTemperature,
            .appleSleepingWristTemperature,
        ]

        for typeId in monitoredTypes {
            guard let sampleType = HKQuantityType.quantityType(forIdentifier: typeId) else { continue }

            // Enable background delivery — iOS wakes the app on new data
            healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { success, error in
                if let error {
                    ActivityLogger.shared.logFromBackground(.health, "BG delivery failed for \(typeId): \(error.localizedDescription)")
                }
            }

            // Observer query fires when new samples arrive
            let sampleTypeKey = sampleType.identifier
            let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { [weak self] _, completionHandler, error in
                // iOS treats `completionHandler()` as an ack; if it doesn't
                // come back within ~30s the system stops delivering. So we
                // ack immediately and run the actual send (debounced) later.
                completionHandler()
                guard error == nil else { return }
                Task { @MainActor [weak self] in
                    self?.observerWakeCounts[sampleTypeKey, default: 0] += 1
                    self?.scheduleDebouncedQueryAndSend()
                }
            }
            healthStore.execute(query)
            observerQueries.append(query)
        }

        // Sleep analysis — category type, handled separately from quantity types
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            healthStore.enableBackgroundDelivery(for: sleepType, frequency: .immediate) { _, error in
                if let error {
                    ActivityLogger.shared.logFromBackground(.health, "BG delivery failed for sleep: \(error.localizedDescription)")
                }
            }

            let sleepKey = sleepType.identifier
            let query = HKObserverQuery(sampleType: sleepType, predicate: nil) { [weak self] _, completionHandler, error in
                completionHandler()
                guard error == nil else { return }
                Task { @MainActor [weak self] in
                    self?.observerWakeCounts[sleepKey, default: 0] += 1
                    self?.scheduleDebouncedQueryAndSend()
                }
            }
            healthStore.execute(query)
            observerQueries.append(query)
        }

        // Workouts — low-frequency, but a fresh workout end is meaningful.
        let workoutType = HKWorkoutType.workoutType()
        healthStore.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { _, error in
            if let error {
                ActivityLogger.shared.logFromBackground(.health, "BG delivery failed for workout: \(error.localizedDescription)")
            }
        }
        let workoutKey = workoutType.identifier
        let workoutQuery = HKObserverQuery(sampleType: workoutType, predicate: nil) { [weak self] _, completionHandler, error in
            completionHandler()
            guard error == nil else { return }
            Task { @MainActor [weak self] in
                self?.observerWakeCounts[workoutKey, default: 0] += 1
                self?.scheduleDebouncedQueryAndSend()
            }
        }
        healthStore.execute(workoutQuery)
        observerQueries.append(workoutQuery)

        startObserverWakeLogger()

        ActivityLogger.shared.log(.health, "Background delivery registered for \(monitoredTypes.count + 2) types (incl. sleep + workout)")
    }

    /// Coalesce observer wakes inside `observerDebounceInterval`. If a recent
    /// queryAndSend happened, the next call is deferred until the window
    /// passes; further wakes inside the window collapse into the same task.
    private func scheduleDebouncedQueryAndSend() {
        guard isEnabled else { return }
        let elapsed = Date().timeIntervalSince(lastObserverSendAt)
        if elapsed >= observerDebounceInterval {
            // Outside the window — fire immediately.
            pendingObserverSendTask?.cancel()
            pendingObserverSendTask = nil
            lastObserverSendAt = Date()
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                await self.queryAndSend()
            }
            return
        }
        // Inside the debounce window — schedule (or replace) the deferred run.
        if pendingObserverSendTask != nil { return }
        let remaining = observerDebounceInterval - elapsed
        pendingObserverSendTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, remaining) * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            self.pendingObserverSendTask = nil
            self.lastObserverSendAt = Date()
            await self.queryAndSend()
        }
    }

    /// Fire hourly timer to log observer wake counts, then reset.
    /// Helps distinguish "observer firing but data missing" vs "observer never fires" (bg delivery dead).
    private func startObserverWakeLogger() {
        observerWakeLogTimer?.invalidate()
        observerWakeLogTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.flushObserverWakeLog()
            }
        }
    }

    private func flushObserverWakeLog() {
        guard !observerWakeCounts.isEmpty else {
            ActivityLogger.shared.log(.health, "Observer wakes (1h): none")
            return
        }
        let line = observerWakeCounts
            .sorted { $0.key < $1.key }
            .map { "\($0.key.shortHK)=\($0.value)" }
            .joined(separator: " ")
        ActivityLogger.shared.log(.health, "Observer wakes (1h): \(line)")
        observerWakeCounts.removeAll()
    }

    /// Stop observer queries (called on disable)
    private func teardownObserverQueries() {
        for query in observerQueries {
            healthStore.stop(query)
        }
        observerQueries.removeAll()
    }

    // MARK: - Timer (supplementary — fires when no new HealthKit data triggers observer)

    func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: sendInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.queryAndSend()
            }
        }
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Query and Send

    func queryAndSend() async {
        await queryAndSend(from: Date().addingTimeInterval(-sendInterval), to: Date())
    }

    func queryAndSendFull() async {
        let now = Date()
        await queryAndSend(from: now.addingTimeInterval(-24 * 3600), to: now)
    }

    private func queryAndSend(from start: Date, to end: Date) async {
        guard isEnabled else { return }

        totalQueries += 1
        lastQueryAt = Date()
        lastSendResult = .sending

        let pair = await aggregateHealthDataPair(from: start, to: end)
        let summary = pair.legacy
        let payload = pair.payload
        lastSummary = summary

        let isBackground = UIApplication.shared.applicationState != .active
        ActivityLogger.shared.log(.health, "Queried \(start.formatted(.dateTime.hour().minute()))–\(end.formatted(.dateTime.hour().minute())) [\(isBackground ? "bg" : "fg")] records=\(payload.records.count)")

        // Skip sending only when nothing at all came back — both the legacy
        // numeric struct and the new record array must be empty.
        let hasAnyData = !payload.records.isEmpty
            || payload.sleep != nil
            || (payload.workouts?.isEmpty == false)
        if !hasAnyData {
            let states = [
                "steps=\(summary.steps.map(String.init) ?? "–")",
                "hr=\(summary.heartRateAvg.map { String(format: "%.0f", $0) } ?? "–")",
                "kcal=\(summary.activeEnergyKcal.map { String(format: "%.0f", $0) } ?? "–")",
                "spO2=\(summary.bloodOxygenPercent.map { String(format: "%.0f", $0) } ?? "–")",
                "resting=\(summary.restingHeartRate.map { String(format: "%.0f", $0) } ?? "–")",
                "hrv=\(summary.hrvAvgMs.map { String(format: "%.0f", $0) } ?? "–")",
                "dist=\(summary.distanceMeters.map { String(format: "%.0f", $0) } ?? "–")",
                "sleep=\(summary.sleepMinutes?.total.map { String(format: "%.0f", $0) } ?? "–")"
            ].joined(separator: " ")
            ActivityLogger.shared.log(.health, "Skipped: auth=\(isAuthorized) \(states)")
            lastSendResult = .error("all metrics nil")
            return
        }

        if isBackground {
            // In background, use TelemetryUploader with beginBackgroundTask for reliable delivery
            await TelemetryUploader.shared.uploadHealthOnly(summary, payload: payload)
            let now = Date()
            lastSentTime = now
            lastAcceptedAt = now
            totalSuccessfulSends += 1
            lastSendResult = .sent(status: 0, body: "bg-queued")
            ActivityLogger.shared.log(.health, "Queued bg upload: \(payload.recordsLogSummary())")
        } else {
            let result = await TelemetryService.shared.sendHealth(summary, payload: payload)
            lastSendResult = result
            if case .sent = result {
                let now = Date()
                lastSentTime = now
                lastAcceptedAt = now
                totalSuccessfulSends += 1
                lastErrorAt = nil
                lastErrorMessage = nil
                ActivityLogger.shared.log(.health, "Sent: \(payload.recordsLogSummary())")
            } else if case .error(let detail) = result {
                totalSendErrors += 1
                recordHealthError(detail)
                ActivityLogger.shared.log(.health, "Error: \(detail)")
            }
        }
    }

    func resetRuntimeCounters() {
        totalQueries = 0
        totalSuccessfulSends = 0
        totalSendErrors = 0
        totalAuthorizationFailures = 0
        lastQueryAt = nil
        lastErrorAt = nil
        lastErrorMessage = nil
        suppressedDuplicateErrors = 0
        errorHistory.removeAll()
        lastSendResult = .none
    }

    // MARK: - Data Aggregation

    func aggregateHealthData(from start: Date, to end: Date) async -> HealthSummary {
        let pair = await aggregateHealthDataPair(from: start, to: end)
        return pair.legacy
    }

    /// Returns both the legacy `HealthSummary` (numeric only, for backward
    /// compatibility) and the new `HealthPayload` (self-describing records
    /// with measurement time + provenance). Callers that send to the server
    /// should prefer the payload; UI code that only needs numbers can use
    /// the legacy struct.
    func aggregateHealthDataPair(from start: Date, to end: Date) async -> (legacy: HealthSummary, payload: HealthPayload) {
        // Per-metric query windows
        // - Cumulative / discrete avg / discrete stats: bounded windows so the
        //   aggregation reflects "today" or "last 24h".
        // - Latest samples: window widened to Date.distantPast so we never drop
        //   a low-frequency measurement (body weight measured weeks ago is still
        //   valid; server uses `measuredAt` to decide how to use it).
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: end)
        let twentyFourHoursAgo = end.addingTimeInterval(-24 * 3600)
        let latestLookback = Date.distantPast

        var summary = HealthSummary(periodStart: todayStart, periodEnd: end)

        // Cumulative daily totals — today 00:00 to now
        async let stepsResult = queryCumulativeSum(.stepCount, unit: .count(), from: todayStart, to: end)
        async let energyResult = queryCumulativeSum(.activeEnergyBurned, unit: .kilocalorie(), from: todayStart, to: end)
        async let basalEnergyResult = queryCumulativeSum(.basalEnergyBurned, unit: .kilocalorie(), from: todayStart, to: end)
        async let distanceResult = queryCumulativeSum(.distanceWalkingRunning, unit: .meter(), from: todayStart, to: end)
        async let flightsResult = queryCumulativeSum(.flightsClimbed, unit: .count(), from: todayStart, to: end)
        // Heart rate — 24h window (smart rings batch-sync, may write hours after measurement)
        async let heartRateResult = queryDiscreteStats(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: twentyFourHoursAgo, to: end)
        // Vitals — discrete averages stay on 24h. Latest samples use distantPast
        // so old values still come through with their measuredAt.
        async let restingHRResult = queryLatestSample(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: latestLookback, to: end)
        async let hrvResult = queryDiscreteAvg(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: twentyFourHoursAgo, to: end)
        async let oxygenResult = queryLatestSample(.oxygenSaturation, unit: .percent(), from: latestLookback, to: end)
        async let respiratoryResult = queryDiscreteAvg(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), from: twentyFourHoursAgo, to: end)
        // Body metrics — distantPast so monthly weigh-ins / occasional body comp
        // measurements are not silently discarded.
        async let bodyMassResult = queryLatestSample(.bodyMass, unit: .gramUnit(with: .kilo), from: latestLookback, to: end)
        async let bodyFatResult = queryLatestSample(.bodyFatPercentage, unit: .percent(), from: latestLookback, to: end)
        async let leanBodyMassResult = queryLatestSample(.leanBodyMass, unit: .gramUnit(with: .kilo), from: latestLookback, to: end)
        async let bmiResult = queryLatestSample(.bodyMassIndex, unit: .count(), from: latestLookback, to: end)
        async let bodyTempResult = queryLatestSample(.bodyTemperature, unit: .degreeCelsius(), from: latestLookback, to: end)
        async let wristTempResult = queryLatestSample(.appleSleepingWristTemperature, unit: .degreeCelsius(), from: latestLookback, to: end)
        // Sleep — look back 24 hours to capture full sleep sessions.
        // Smart rings may write sleep samples with early startDates (naps, early bedtime).
        let sleepLookback = twentyFourHoursAgo
        async let sleepResult = querySleep(from: sleepLookback, to: end)
        async let workoutsResult = queryWorkouts(from: todayStart, to: end)

        // Resolve all query results once.
        let steps = await stepsResult
        let energy = await energyResult
        let basalEnergy = await basalEnergyResult
        let distance = await distanceResult
        let flights = await flightsResult
        let heartRate = await heartRateResult
        let restingHR = await restingHRResult
        let hrv = await hrvResult
        let oxygen = await oxygenResult
        let respiratory = await respiratoryResult
        let bodyMass = await bodyMassResult
        let bodyFat = await bodyFatResult
        let leanBodyMass = await leanBodyMassResult
        let bmi = await bmiResult
        let bodyTemp = await bodyTempResult
        let wristTemp = await wristTempResult
        let sleep = await sleepResult
        let workouts = await workoutsResult

        // --- Populate legacy HealthSummary (numeric only) ---
        if let s = steps { summary.steps = Int(s.value) }
        summary.activeEnergyKcal = energy?.value
        summary.basalEnergyKcal = basalEnergy?.value
        summary.distanceMeters = distance?.value
        if let f = flights { summary.flightsClimbed = Int(f.value) }

        if let hr = heartRate {
            summary.heartRateAvg = hr.avg
            summary.heartRateMin = hr.min
            summary.heartRateMax = hr.max
        }

        summary.restingHeartRate = restingHR?.value
        summary.hrvAvgMs = hrv?.avg

        if let o = oxygen { summary.bloodOxygenPercent = o.value * 100 }

        summary.respiratoryRateAvg = respiratory?.avg
        summary.bodyMassKg = bodyMass?.value
        if let bf = bodyFat { summary.bodyFatPercent = bf.value * 100 }
        summary.leanBodyMassKg = leanBodyMass?.value
        summary.bmi = bmi?.value
        summary.bodyTemperatureCelsius = bodyTemp?.value
        summary.wristTemperatureCelsius = wristTemp?.value
        summary.sleepMinutes = sleep
        summary.workouts = workouts

        // --- Build self-describing HealthPayload ---
        var records: [HealthRecord] = []

        func appendCumulative(_ id: HKQuantityTypeIdentifier, _ result: CumulativeSumResult?, unit: String) {
            guard let r = result else { return }
            records.append(HealthRecord(
                metricId: id.rawValue,
                value: r.value,
                valueText: nil,
                valueMin: nil, valueMax: nil,
                unit: unit,
                aggregation: "cumulativeSum",
                measuredAt: r.intervalEnd,
                intervalStart: r.intervalStart,
                intervalEnd: r.intervalEnd,
                sampleCount: r.sampleCount,
                source: r.source,
                sourceBundleId: r.sourceBundleId,
                deviceModel: r.deviceModel
            ))
        }
        func appendLatest(_ id: HKQuantityTypeIdentifier, _ result: LatestSampleResult?, unit: String, scaleToPercent: Bool = false) {
            guard let r = result else { return }
            let v = scaleToPercent ? r.value * 100 : r.value
            records.append(HealthRecord(
                metricId: id.rawValue,
                value: v,
                valueText: nil,
                valueMin: nil, valueMax: nil,
                unit: unit,
                aggregation: "latest",
                measuredAt: r.measuredAt,
                intervalStart: nil, intervalEnd: nil,
                sampleCount: nil,
                source: r.source,
                sourceBundleId: r.sourceBundleId,
                deviceModel: r.deviceModel
            ))
        }
        func appendAvg(_ id: HKQuantityTypeIdentifier, _ result: DiscreteAvgResult?, unit: String) {
            guard let r = result else { return }
            records.append(HealthRecord(
                metricId: id.rawValue,
                value: r.avg,
                valueText: nil,
                valueMin: nil, valueMax: nil,
                unit: unit,
                aggregation: "discreteAvg",
                measuredAt: r.intervalEnd,
                intervalStart: r.intervalStart,
                intervalEnd: r.intervalEnd,
                sampleCount: r.sampleCount,
                source: r.source,
                sourceBundleId: r.sourceBundleId,
                deviceModel: r.deviceModel
            ))
        }
        func appendStats(_ id: HKQuantityTypeIdentifier, _ result: DiscreteStatsResult?, unit: String) {
            guard let r = result else { return }
            records.append(HealthRecord(
                metricId: id.rawValue,
                value: r.avg,
                valueText: nil,
                valueMin: r.min, valueMax: r.max,
                unit: unit,
                aggregation: "discreteStats",
                measuredAt: r.intervalEnd,
                intervalStart: r.intervalStart,
                intervalEnd: r.intervalEnd,
                sampleCount: r.sampleCount,
                source: r.source,
                sourceBundleId: r.sourceBundleId,
                deviceModel: r.deviceModel
            ))
        }

        appendCumulative(.stepCount, steps, unit: "count")
        appendCumulative(.activeEnergyBurned, energy, unit: "kcal")
        appendCumulative(.basalEnergyBurned, basalEnergy, unit: "kcal")
        appendCumulative(.distanceWalkingRunning, distance, unit: "m")
        appendCumulative(.flightsClimbed, flights, unit: "count")

        appendStats(.heartRate, heartRate, unit: "count/min")
        appendLatest(.restingHeartRate, restingHR, unit: "count/min")
        appendAvg(.heartRateVariabilitySDNN, hrv, unit: "ms")
        appendLatest(.oxygenSaturation, oxygen, unit: "%", scaleToPercent: true)
        appendAvg(.respiratoryRate, respiratory, unit: "count/min")

        appendLatest(.bodyMass, bodyMass, unit: "kg")
        appendLatest(.bodyFatPercentage, bodyFat, unit: "%", scaleToPercent: true)
        appendLatest(.leanBodyMass, leanBodyMass, unit: "kg")
        appendLatest(.bodyMassIndex, bmi, unit: "count")
        appendLatest(.bodyTemperature, bodyTemp, unit: "degC")
        appendLatest(.appleSleepingWristTemperature, wristTemp, unit: "degC")

        let payload = HealthPayload(
            collectedAt: end,
            records: records,
            sleep: sleep,
            workouts: workouts
        )

        return (summary, payload)
    }

    // MARK: - Query Helpers

    // MARK: - Intermediate result types (carry timestamp + provenance)
    //
    // Each query helper returns one of these so the aggregator can populate
    // both the legacy `HealthSummary` (numeric only) and the new
    // `HealthPayload` (self-describing record per metric).

    struct LatestSampleResult {
        let value: Double
        let measuredAt: Date
        let source: String?
        let sourceBundleId: String?
        let deviceModel: String?
    }

    struct CumulativeSumResult {
        let value: Double
        let intervalStart: Date
        let intervalEnd: Date
        /// Optional — provenance is "representative latest sample" only,
        /// taken via limit=1 query to avoid scanning thousands of samples
        /// per HR/HRV background wake. nil when not retrieved.
        let sampleCount: Int?
        let source: String?
        let sourceBundleId: String?
        let deviceModel: String?
    }

    struct DiscreteAvgResult {
        let avg: Double
        let intervalStart: Date
        let intervalEnd: Date
        let sampleCount: Int?
        let source: String?
        let sourceBundleId: String?
        let deviceModel: String?
    }

    struct DiscreteStatsResult {
        let avg: Double
        let min: Double
        let max: Double
        let intervalStart: Date
        let intervalEnd: Date
        let sampleCount: Int?
        let source: String?
        let sourceBundleId: String?
        let deviceModel: String?
    }

    private func queryCumulativeSum(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> CumulativeSumResult? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            Self.logHK("\(identifier.rawValue.shortHK): type-unavailable")
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        let stats: HKStatistics? = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                if let error {
                    Self.logHK("\(identifier.rawValue.shortHK): err(\(error.localizedDescription))")
                }
                continuation.resume(returning: stats)
            }
            healthStore.execute(query)
        }

        guard let stats, let value = stats.sumQuantity()?.doubleValue(for: unit) else {
            Self.logHK("\(identifier.rawValue.shortHK): empty")
            return nil
        }

        // Resolve source/device + sample count via a quick contributing-samples scan.
        let provenance = await fetchProvenance(type: type, predicate: predicate)
        Self.logHK("\(identifier.rawValue.shortHK): \(String(format: "%.1f", value)) src=\(provenance.source ?? "n/a")")
        return CumulativeSumResult(
            value: value,
            intervalStart: start,
            intervalEnd: end,
            sampleCount: provenance.sampleCount,
            source: provenance.source,
            sourceBundleId: provenance.sourceBundleId,
            deviceModel: provenance.deviceModel
        )
    }

    private func queryDiscreteStats(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> DiscreteStatsResult? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            Self.logHK("\(identifier.rawValue.shortHK): type-unavailable")
            return nil
        }
        // .strictEndDate: smart ring samples may have startDate before the window
        // but endDate inside the window (batched overnight syncs).
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)

        let stats: HKStatistics? = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMin, .discreteMax]
            ) { _, stats, error in
                if let error {
                    Self.logHK("\(identifier.rawValue.shortHK): err(\(error.localizedDescription))")
                }
                continuation.resume(returning: stats)
            }
            healthStore.execute(query)
        }

        guard let stats,
              let avg = stats.averageQuantity()?.doubleValue(for: unit),
              let mn = stats.minimumQuantity()?.doubleValue(for: unit),
              let mx = stats.maximumQuantity()?.doubleValue(for: unit) else {
            Self.logHK("\(identifier.rawValue.shortHK): empty")
            return nil
        }

        let provenance = await fetchProvenance(type: type, predicate: predicate)
        Self.logHK("\(identifier.rawValue.shortHK): avg=\(String(format: "%.1f", avg)) min=\(String(format: "%.1f", mn)) max=\(String(format: "%.1f", mx)) src=\(provenance.source ?? "n/a")")
        return DiscreteStatsResult(
            avg: avg, min: mn, max: mx,
            intervalStart: start,
            intervalEnd: end,
            sampleCount: provenance.sampleCount,
            source: provenance.source,
            sourceBundleId: provenance.sourceBundleId,
            deviceModel: provenance.deviceModel
        )
    }

    private func queryDiscreteAvg(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> DiscreteAvgResult? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            Self.logHK("\(identifier.rawValue.shortHK): type-unavailable")
            return nil
        }
        // .strictEndDate for smart ring batch-sync samples
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)

        let stats: HKStatistics? = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, error in
                if let error {
                    Self.logHK("\(identifier.rawValue.shortHK): err(\(error.localizedDescription))")
                }
                continuation.resume(returning: stats)
            }
            healthStore.execute(query)
        }

        guard let stats, let value = stats.averageQuantity()?.doubleValue(for: unit) else {
            Self.logHK("\(identifier.rawValue.shortHK): empty")
            return nil
        }

        let provenance = await fetchProvenance(type: type, predicate: predicate)
        Self.logHK("\(identifier.rawValue.shortHK): avg=\(String(format: "%.1f", value)) src=\(provenance.source ?? "n/a")")
        return DiscreteAvgResult(
            avg: value,
            intervalStart: start,
            intervalEnd: end,
            sampleCount: provenance.sampleCount,
            source: provenance.source,
            sourceBundleId: provenance.sourceBundleId,
            deviceModel: provenance.deviceModel
        )
    }

    private func queryLatestSample(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> LatestSampleResult? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            Self.logHK("\(identifier.rawValue.shortHK): type-unavailable")
            return nil
        }
        // .strictEndDate for smart ring batch-sync samples
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                guard let sample = samples?.first as? HKQuantitySample else {
                    Self.logHK("\(identifier.rawValue.shortHK): \(error.map { "err(\($0.localizedDescription))" } ?? "empty")")
                    continuation.resume(returning: nil)
                    return
                }
                let value = sample.quantity.doubleValue(for: unit)
                let result = LatestSampleResult(
                    value: value,
                    measuredAt: sample.endDate,
                    source: sample.sourceRevision.source.name,
                    sourceBundleId: sample.sourceRevision.source.bundleIdentifier,
                    deviceModel: sample.device?.model
                )
                Self.logHK("\(identifier.rawValue.shortHK): \(String(format: "%.2f", value)) at=\(sample.endDate.formatted(.iso8601)) src=\(sample.sourceRevision.source.name)")
                continuation.resume(returning: result)
            }
            healthStore.execute(query)
        }
    }

    private struct ProvenanceInfo {
        /// Always nil from this lightweight path (limit=1 cannot count). Reserved
        /// for a future opt-in pass on a small allowlist of metrics.
        let sampleCount: Int?
        let source: String?
        let sourceBundleId: String?
        let deviceModel: String?
    }

    /// Lightweight provenance lookup for aggregate statistics. Reads only the
    /// most recent contributing sample (limit=1, sorted by endDate desc) to
    /// surface a *representative* source/device. Avoids the original
    /// `HKObjectQueryNoLimit` scan that would pull thousands of HR samples
    /// during a background wake.
    ///
    /// Caveats (per Cdx audit):
    /// - This is a "representative" source, not a full breakdown. Aggregates
    ///   that span multiple sources (e.g. steps from iPhone + Apple Watch +
    ///   third-party app) will only reflect the latest writer.
    /// - `sampleCount` is intentionally nil here. Server should treat
    ///   aggregate provenance as best-effort, and use `sleep.segments` /
    ///   `workouts[]` / latest records for stable routing.
    private func fetchProvenance(
        type: HKQuantityType,
        predicate: NSPredicate
    ) async -> ProvenanceInfo {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                let latest = (samples?.first as? HKQuantitySample)
                continuation.resume(returning: ProvenanceInfo(
                    sampleCount: nil,
                    source: latest?.sourceRevision.source.name,
                    sourceBundleId: latest?.sourceRevision.source.bundleIdentifier,
                    deviceModel: latest?.device?.model
                ))
            }
            healthStore.execute(query)
        }
    }

    private func querySleep(from start: Date, to end: Date) async -> SleepSummary? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        // Use .strictEndDate to capture sleep sessions that END within the window.
        // Smart rings may write sleep samples with startDate before the 14h lookback
        // (e.g. early evening nap at 18:00), and .strictStartDate would miss them.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, error in
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
                    Self.logHK("sleep: \(error.map { "err(\($0.localizedDescription))" } ?? "empty")")
                    continuation.resume(returning: nil)
                    return
                }

                var summary = SleepSummary()
                var totalMinutes: Double = 0
                var segments: [SleepSegment] = []

                for sample in samples {
                    let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60.0

                    let stageName: String?
                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        summary.rem = (summary.rem ?? 0) + minutes
                        totalMinutes += minutes
                        stageName = "asleepREM"
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        summary.deep = (summary.deep ?? 0) + minutes
                        totalMinutes += minutes
                        stageName = "asleepDeep"
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                        summary.core = (summary.core ?? 0) + minutes
                        totalMinutes += minutes
                        stageName = "asleepCore"
                    case HKCategoryValueSleepAnalysis.awake.rawValue:
                        summary.awake = (summary.awake ?? 0) + minutes
                        stageName = "awake"
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        totalMinutes += minutes
                        stageName = "asleepUnspecified"
                    case HKCategoryValueSleepAnalysis.inBed.rawValue:
                        stageName = "inBed"
                    default:
                        stageName = nil
                    }

                    if let stageName {
                        segments.append(SleepSegment(
                            start: sample.startDate,
                            end: sample.endDate,
                            stage: stageName,
                            source: sample.sourceRevision.source.name,
                            sourceBundleId: sample.sourceRevision.source.bundleIdentifier,
                            deviceModel: sample.device?.model
                        ))
                    }
                }

                summary.total = totalMinutes
                summary.segments = segments.isEmpty ? nil : segments
                Self.logHK("sleep: total=\(String(format: "%.0f", totalMinutes))m deep=\(Int(summary.deep ?? 0)) rem=\(Int(summary.rem ?? 0)) core=\(Int(summary.core ?? 0)) awake=\(Int(summary.awake ?? 0)) segments=\(segments.count) n=\(samples.count)")
                continuation.resume(returning: summary)
            }
            healthStore.execute(query)
        }
    }

    private func queryWorkouts(from start: Date, to end: Date) async -> [WorkoutSummary]? {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKWorkoutType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let workouts = samples as? [HKWorkout], !workouts.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                let summaries = workouts.map { workout in
                    WorkoutSummary(
                        activityType: Self.workoutActivityName(workout.workoutActivityType),
                        durationSeconds: workout.duration,
                        energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        distanceMeters: workout.totalDistance?.doubleValue(for: .meter()),
                        start: workout.startDate,
                        end: workout.endDate,
                        source: workout.sourceRevision.source.name,
                        sourceBundleId: workout.sourceRevision.source.bundleIdentifier,
                        deviceModel: workout.device?.model
                    )
                }

                continuation.resume(returning: summaries)
            }
            healthStore.execute(query)
        }
    }

    private nonisolated static func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .yoga: return "yoga"
        case .functionalStrengthTraining: return "strength_training"
        case .traditionalStrengthTraining: return "strength_training"
        case .highIntensityIntervalTraining: return "hiit"
        case .elliptical: return "elliptical"
        case .rowing: return "rowing"
        case .stairClimbing: return "stair_climbing"
        case .hiking: return "hiking"
        case .dance: return "dance"
        case .cooldown: return "cooldown"
        case .coreTraining: return "core_training"
        case .pilates: return "pilates"
        case .mixedCardio: return "mixed_cardio"
        default: return "other"
        }
    }
}

private extension HealthKitManager {
    /// Nonisolated log helper — safe to call from HKSampleQuery/HKStatisticsQuery
    /// completion handlers which run on background queues.
    nonisolated static func logHK(_ message: String) {
        ActivityLogger.shared.logFromBackground(.health, "HK " + message)
    }
}

private extension String {
    /// Short forms for HealthKit identifier raw values to keep log lines compact.
    /// e.g. "HKQuantityTypeIdentifierHeartRate" -> "heartRate"
    var shortHK: String {
        let prefix = "HKQuantityTypeIdentifier"
        if hasPrefix(prefix) {
            let trimmed = String(dropFirst(prefix.count))
            return trimmed.prefix(1).lowercased() + trimmed.dropFirst()
        }
        return self
    }
}

private extension HealthKitManager {
    func recordHealthError(_ message: String) {
        let now = Date()
        lastErrorAt = now
        lastErrorMessage = message
        if let first = errorHistory.first,
           first.message == message,
           now.timeIntervalSince(first.timestamp) < Self.errorDedupWindow {
            suppressedDuplicateErrors += 1
            return
        }

        errorHistory.insert(HealthNetworkError(timestamp: now, message: message), at: 0)
        if errorHistory.count > Self.maxErrorHistoryCount {
            errorHistory.removeLast()
        }
    }
}
