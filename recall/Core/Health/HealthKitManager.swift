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

        let monitoredTypes: [HKQuantityTypeIdentifier] = [
            .stepCount,
            .heartRate,
            .heartRateVariabilitySDNN,
            .oxygenSaturation,
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
                guard error == nil else {
                    completionHandler()
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self, self.isEnabled else {
                        completionHandler()
                        return
                    }
                    self.observerWakeCounts[sampleTypeKey, default: 0] += 1
                    await self.queryAndSend()
                    completionHandler()
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
                guard error == nil else {
                    completionHandler()
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, self.isEnabled else {
                        completionHandler()
                        return
                    }
                    self.observerWakeCounts[sleepKey, default: 0] += 1
                    await self.queryAndSend()
                    completionHandler()
                }
            }
            healthStore.execute(query)
            observerQueries.append(query)
        }

        startObserverWakeLogger()

        ActivityLogger.shared.log(.health, "Background delivery registered for \(monitoredTypes.count + 1) types (incl. sleep)")
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

        let summary = await aggregateHealthData(from: start, to: end)
        lastSummary = summary

        let isBackground = UIApplication.shared.applicationState != .active
        ActivityLogger.shared.log(.health, "Queried \(start.formatted(.dateTime.hour().minute()))–\(end.formatted(.dateTime.hour().minute())) [\(isBackground ? "bg" : "fg")]")

        // Skip sending if all health metrics are nil — prevents overwriting good data on server
        let hasAnyData = summary.steps != nil || summary.heartRateAvg != nil
            || summary.activeEnergyKcal != nil || summary.bloodOxygenPercent != nil
            || summary.restingHeartRate != nil || summary.hrvAvgMs != nil
            || summary.distanceMeters != nil || summary.sleepMinutes != nil
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
            await TelemetryUploader.shared.uploadHealthOnly(summary)
            let now = Date()
            lastSentTime = now
            lastAcceptedAt = now
            totalSuccessfulSends += 1
            lastSendResult = .sent(status: 0, body: "bg-queued")
            ActivityLogger.shared.log(.health, "Queued bg upload: steps=\(summary.steps ?? 0) hr=\(summary.heartRateAvg.map { String(format: "%.0f", $0) } ?? "–")")
        } else {
            let result = await TelemetryService.shared.sendHealth(summary)
            lastSendResult = result
            if case .sent = result {
                let now = Date()
                lastSentTime = now
                lastAcceptedAt = now
                totalSuccessfulSends += 1
                lastErrorAt = nil
                lastErrorMessage = nil
                ActivityLogger.shared.log(.health, "Sent: steps=\(summary.steps ?? 0) hr=\(summary.heartRateAvg.map { String(format: "%.0f", $0) } ?? "–")")
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
        // Per-metric query windows — widened for smart ring batch sync patterns
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: end)
        let twentyFourHoursAgo = end.addingTimeInterval(-24 * 3600)
        let fourteenDaysAgo = end.addingTimeInterval(-14 * 24 * 3600)

        var summary = HealthSummary(periodStart: todayStart, periodEnd: end)

        // Cumulative daily totals — today 00:00 to now
        async let stepsResult = queryCumulativeSum(.stepCount, unit: .count(), from: todayStart, to: end)
        async let energyResult = queryCumulativeSum(.activeEnergyBurned, unit: .kilocalorie(), from: todayStart, to: end)
        async let basalEnergyResult = queryCumulativeSum(.basalEnergyBurned, unit: .kilocalorie(), from: todayStart, to: end)
        async let distanceResult = queryCumulativeSum(.distanceWalkingRunning, unit: .meter(), from: todayStart, to: end)
        async let flightsResult = queryCumulativeSum(.flightsClimbed, unit: .count(), from: todayStart, to: end)
        // Heart rate — 24h window (smart rings batch-sync, may write hours after measurement)
        async let heartRateResult = queryDiscreteStats(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: twentyFourHoursAgo, to: end)
        // Vitals — last 24 hours (resting HR, HRV, SpO2 are typically calculated once per sleep/day)
        async let restingHRResult = queryLatestSample(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: twentyFourHoursAgo, to: end)
        async let hrvResult = queryDiscreteAvg(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: twentyFourHoursAgo, to: end)
        async let oxygenResult = queryLatestSample(.oxygenSaturation, unit: .percent(), from: twentyFourHoursAgo, to: end)
        async let respiratoryResult = queryDiscreteAvg(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), from: twentyFourHoursAgo, to: end)
        // Body metrics — 14 days for low-frequency body composition measurements
        async let bodyMassResult = queryLatestSample(.bodyMass, unit: .gramUnit(with: .kilo), from: fourteenDaysAgo, to: end)
        async let bodyFatResult = queryLatestSample(.bodyFatPercentage, unit: .percent(), from: fourteenDaysAgo, to: end)
        async let leanBodyMassResult = queryLatestSample(.leanBodyMass, unit: .gramUnit(with: .kilo), from: fourteenDaysAgo, to: end)
        async let bmiResult = queryLatestSample(.bodyMassIndex, unit: .count(), from: fourteenDaysAgo, to: end)
        async let bodyTempResult = queryLatestSample(.bodyTemperature, unit: .degreeCelsius(), from: twentyFourHoursAgo, to: end)
        async let wristTempResult = queryLatestSample(.appleSleepingWristTemperature, unit: .degreeCelsius(), from: twentyFourHoursAgo, to: end)
        // Sleep — look back 24 hours to capture full sleep sessions.
        // Smart rings may write sleep samples with early startDates (naps, early bedtime).
        // 14h was too short and caused partial sleep data (e.g. 1.9h instead of full night).
        let sleepLookback = twentyFourHoursAgo
        async let sleepResult = querySleep(from: sleepLookback, to: end)
        async let workoutsResult = queryWorkouts(from: todayStart, to: end)

        if let steps = await stepsResult {
            summary.steps = Int(steps)
        }
        summary.activeEnergyKcal = await energyResult
        summary.basalEnergyKcal = await basalEnergyResult
        summary.distanceMeters = await distanceResult
        if let flights = await flightsResult {
            summary.flightsClimbed = Int(flights)
        }

        if let hr = await heartRateResult {
            summary.heartRateAvg = hr.avg
            summary.heartRateMin = hr.min
            summary.heartRateMax = hr.max
        }

        summary.restingHeartRate = await restingHRResult
        summary.hrvAvgMs = await hrvResult

        if let oxygen = await oxygenResult {
            summary.bloodOxygenPercent = oxygen * 100
        }

        summary.respiratoryRateAvg = await respiratoryResult
        summary.bodyMassKg = await bodyMassResult
        if let bodyFat = await bodyFatResult {
            summary.bodyFatPercent = bodyFat * 100
        }
        summary.leanBodyMassKg = await leanBodyMassResult
        summary.bmi = await bmiResult
        summary.bodyTemperatureCelsius = await bodyTempResult
        summary.wristTemperatureCelsius = await wristTempResult
        summary.sleepMinutes = await sleepResult
        summary.workouts = await workoutsResult

        return summary
    }

    // MARK: - Query Helpers

    private func queryCumulativeSum(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            Self.logHK("\(identifier.rawValue.shortHK): type-unavailable")
            return nil
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, error in
                let value = stats?.sumQuantity()?.doubleValue(for: unit)
                Self.logHK("\(identifier.rawValue.shortHK): \(value.map { String(format: "%.1f", $0) } ?? (error.map { "err(\($0.localizedDescription))" } ?? "empty"))")
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    private func queryDiscreteStats(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> (avg: Double, min: Double, max: Double)? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            Self.logHK("\(identifier.rawValue.shortHK): type-unavailable")
            return nil
        }
        // .strictEndDate: smart ring samples may have startDate before the window
        // but endDate inside the window (batched overnight syncs).
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMin, .discreteMax]
            ) { _, stats, error in
                guard let avg = stats?.averageQuantity()?.doubleValue(for: unit),
                      let min = stats?.minimumQuantity()?.doubleValue(for: unit),
                      let max = stats?.maximumQuantity()?.doubleValue(for: unit) else {
                    Self.logHK("\(identifier.rawValue.shortHK): \(error.map { "err(\($0.localizedDescription))" } ?? "empty")")
                    continuation.resume(returning: nil)
                    return
                }
                Self.logHK("\(identifier.rawValue.shortHK): avg=\(String(format: "%.1f", avg)) min=\(String(format: "%.1f", min)) max=\(String(format: "%.1f", max))")
                continuation.resume(returning: (avg, min, max))
            }
            healthStore.execute(query)
        }
    }

    private func queryDiscreteAvg(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            Self.logHK("\(identifier.rawValue.shortHK): type-unavailable")
            return nil
        }
        // .strictEndDate for smart ring batch-sync samples
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, error in
                let value = stats?.averageQuantity()?.doubleValue(for: unit)
                Self.logHK("\(identifier.rawValue.shortHK): \(value.map { "avg=" + String(format: "%.1f", $0) } ?? (error.map { "err(\($0.localizedDescription))" } ?? "empty"))")
                continuation.resume(returning: value)
            }
            healthStore.execute(query)
        }
    }

    private func queryLatestSample(
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date
    ) async -> Double? {
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
                let value = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit)
                Self.logHK("\(identifier.rawValue.shortHK): \(value.map { String(format: "%.2f", $0) } ?? (error.map { "err(\($0.localizedDescription))" } ?? "empty"))")
                continuation.resume(returning: value)
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

                for sample in samples {
                    let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60.0

                    switch sample.value {
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        summary.rem = (summary.rem ?? 0) + minutes
                        totalMinutes += minutes
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        summary.deep = (summary.deep ?? 0) + minutes
                        totalMinutes += minutes
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                        summary.core = (summary.core ?? 0) + minutes
                        totalMinutes += minutes
                    case HKCategoryValueSleepAnalysis.awake.rawValue:
                        summary.awake = (summary.awake ?? 0) + minutes
                    case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        totalMinutes += minutes
                    default:
                        break
                    }
                }

                summary.total = totalMinutes
                Self.logHK("sleep: total=\(String(format: "%.0f", totalMinutes))m deep=\(Int(summary.deep ?? 0)) rem=\(Int(summary.rem ?? 0)) core=\(Int(summary.core ?? 0)) awake=\(Int(summary.awake ?? 0)) n=\(samples.count)")
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
                        end: workout.endDate
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
