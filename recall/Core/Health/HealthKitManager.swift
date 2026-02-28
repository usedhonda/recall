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
    private var sendInterval: TimeInterval {
        AppSettings.shared.telemetrySendInterval  // same as Location (default 60s)
    }

    // MARK: - Initialization

    init() {}

    /// Restore enabled state from AppSettings
    func restoreSettings() {
        let savedEnabled = AppSettings.shared.healthEnabled
        if savedEnabled && HKHealthStore.isHealthDataAvailable() {
            isEnabled = true
        }
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
            .distanceWalkingRunning,
            .oxygenSaturation,
            .respiratoryRate,
            .bodyMass,
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
    /// Call this from AppDelegate.didFinishLaunchingWithOptions.
    func setupBackgroundDelivery() {
        guard HKHealthStore.isHealthDataAvailable() else { return }

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
                    await self.queryAndSend()
                    completionHandler()
                }
            }
            healthStore.execute(query)
            observerQueries.append(query)
        }

        ActivityLogger.shared.log(.health, "Background delivery registered for \(monitoredTypes.count) types")
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
        var summary = HealthSummary(periodStart: start, periodEnd: end)

        async let stepsResult = queryCumulativeSum(.stepCount, unit: .count(), from: start, to: end)
        async let energyResult = queryCumulativeSum(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end)
        async let distanceResult = queryCumulativeSum(.distanceWalkingRunning, unit: .meter(), from: start, to: end)
        async let heartRateResult = queryDiscreteStats(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)
        async let restingHRResult = queryLatestSample(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)
        async let hrvResult = queryDiscreteAvg(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: start, to: end)
        async let oxygenResult = queryLatestSample(.oxygenSaturation, unit: .percent(), from: start, to: end)
        async let respiratoryResult = queryDiscreteAvg(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), from: start, to: end)
        async let bodyMassResult = queryLatestSample(.bodyMass, unit: .gramUnit(with: .kilo), from: start, to: end)
        async let bodyTempResult = queryLatestSample(.bodyTemperature, unit: .degreeCelsius(), from: start, to: end)
        async let wristTempResult = queryLatestSample(.appleSleepingWristTemperature, unit: .degreeCelsius(), from: start, to: end)
        async let sleepResult = querySleep(from: start, to: end)
        async let workoutsResult = queryWorkouts(from: start, to: end)

        if let steps = await stepsResult {
            summary.steps = Int(steps)
        }
        summary.activeEnergyKcal = await energyResult
        summary.distanceMeters = await distanceResult

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
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
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
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: [.discreteAverage, .discreteMin, .discreteMax]
            ) { _, stats, _ in
                guard let avg = stats?.averageQuantity()?.doubleValue(for: unit),
                      let min = stats?.minimumQuantity()?.doubleValue(for: unit),
                      let max = stats?.maximumQuantity()?.doubleValue(for: unit) else {
                    continuation.resume(returning: nil)
                    return
                }
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
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .discreteAverage
            ) { _, stats, _ in
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
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
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                continuation.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            healthStore.execute(query)
        }
    }

    private func querySleep(from start: Date, to end: Date) async -> SleepSummary? {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sleepType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                guard let samples = samples as? [HKCategorySample], !samples.isEmpty else {
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
