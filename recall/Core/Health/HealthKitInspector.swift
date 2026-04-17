import Foundation
import HealthKit

@MainActor
final class HealthKitInspector {
    struct TypeReport: Identifiable, Sendable {
        let identifier: String
        let authorizationStatus: HKAuthorizationStatus
        let sampleCount7d: Int
        let latestStart: Date?
        let latestEnd: Date?
        let latestValue: String?
        let latestSourceName: String?
        let latestSourceBundleId: String?

        var id: String { identifier }
    }

    private enum Descriptor {
        case quantity(HKQuantityTypeIdentifier)
        case category(HKCategoryTypeIdentifier)
        case workout

        var identifier: String {
            switch self {
            case .quantity(let id):
                return id.rawValue
            case .category(let id):
                return id.rawValue
            case .workout:
                return HKWorkoutType.workoutType().identifier
            }
        }

        var objectType: HKObjectType? {
            switch self {
            case .quantity(let id):
                return HKQuantityType.quantityType(forIdentifier: id)
            case .category(let id):
                return HKObjectType.categoryType(forIdentifier: id)
            case .workout:
                return HKWorkoutType.workoutType()
            }
        }

        var sampleType: HKSampleType? {
            objectType as? HKSampleType
        }
    }

    private let healthStore = HKHealthStore()

    private let baseDescriptors: [Descriptor] = [
        .quantity(.stepCount),
        .quantity(.heartRate),
        .quantity(.restingHeartRate),
        .quantity(.heartRateVariabilitySDNN),
        .quantity(.activeEnergyBurned),
        .quantity(.distanceWalkingRunning),
        .quantity(.oxygenSaturation),
        .quantity(.respiratoryRate),
        .quantity(.bodyMass),
        .quantity(.bodyTemperature),
        .quantity(.appleSleepingWristTemperature),
        .category(.sleepAnalysis),
        .workout,
    ]

    private let extendedDescriptors: [Descriptor] = [
        .quantity(.bodyFatPercentage),
        .quantity(.leanBodyMass),
        .quantity(.bodyMassIndex),
        .quantity(.basalEnergyBurned),
        .quantity(.walkingHeartRateAverage),
        .quantity(.heartRateRecoveryOneMinute),
        .quantity(.vo2Max),
        .quantity(.flightsClimbed),
        .quantity(.appleStandTime),
        .quantity(.appleExerciseTime),
        .quantity(.height),
    ]

    private lazy var descriptorByIdentifier: [String: Descriptor] = {
        Dictionary(uniqueKeysWithValues: (baseDescriptors + extendedDescriptors).map { ($0.identifier, $0) })
    }()

    func scan(includeExtended: Bool) async -> [TypeReport] {
        let descriptors = includeExtended ? (baseDescriptors + extendedDescriptors) : baseDescriptors
        var reports: [TypeReport] = []
        reports.reserveCapacity(descriptors.count)

        for descriptor in descriptors {
            if let report = await report(for: descriptor) {
                reports.append(report)
            }
        }

        return reports.sorted { $0.identifier < $1.identifier }
    }

    func requestExtendedAuthorization() async -> Bool {
        let readTypes = Set(extendedDescriptors.compactMap(\.objectType))
        guard !readTypes.isEmpty else { return true }

        do {
            try await healthStore.requestAuthorization(toShare: [], read: readTypes)
            return true
        } catch {
            ActivityLogger.shared.log(.health, "Inspector auth failed: \(error.localizedDescription)")
            return false
        }
    }

    func fetchSampleExamples(identifier: String) async -> [String] {
        guard let descriptor = descriptorByIdentifier[identifier],
              let sampleType = descriptor.sampleType
        else {
            return []
        }

        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-7 * 24 * 60 * 60),
            end: Date(),
            options: .strictEndDate
        )
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: 5,
                sortDescriptors: [sortDescriptor]
            ) { [weak self] _, samples, _ in
                guard let self, let samples else {
                    continuation.resume(returning: [])
                    return
                }
                let lines = samples.map { self.formatExample(sample: $0, descriptor: descriptor) }
                continuation.resume(returning: lines)
            }
            healthStore.execute(query)
        }
    }

    private func report(for descriptor: Descriptor) async -> TypeReport? {
        guard let objectType = descriptor.objectType,
              let sampleType = descriptor.sampleType
        else {
            return nil
        }

        let authorizationStatus = healthStore.authorizationStatus(for: objectType)
        let rangeStart = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let predicate = HKQuery.predicateForSamples(withStart: rangeStart, end: Date(), options: .strictEndDate)
        let sampleCount7d = await countSamples(sampleType: sampleType, predicate: predicate)
        let latestSample = await fetchLatestSample(sampleType: sampleType, predicate: predicate)

        return TypeReport(
            identifier: descriptor.identifier,
            authorizationStatus: authorizationStatus,
            sampleCount7d: sampleCount7d,
            latestStart: latestSample?.startDate,
            latestEnd: latestSample?.endDate,
            latestValue: latestSample.flatMap { formatLatestValue(sample: $0, descriptor: descriptor) },
            latestSourceName: latestSample?.sourceRevision.source.name,
            latestSourceBundleId: latestSample?.sourceRevision.source.bundleIdentifier
        )
    }

    private func countSamples(sampleType: HKSampleType, predicate: NSPredicate?) async -> Int {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, _ in
                continuation.resume(returning: samples?.count ?? 0)
            }
            healthStore.execute(query)
        }
    }

    private func fetchLatestSample(sampleType: HKSampleType, predicate: NSPredicate?) async -> HKSample? {
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: 1,
                sortDescriptors: [sortDescriptor]
            ) { _, samples, _ in
                continuation.resume(returning: samples?.first)
            }
            healthStore.execute(query)
        }
    }

    private func formatLatestValue(sample: HKSample, descriptor: Descriptor) -> String? {
        switch descriptor {
        case .quantity(let identifier):
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            return formatQuantity(quantitySample.quantity, identifier: identifier)
        case .category(.sleepAnalysis):
            guard let categorySample = sample as? HKCategorySample else { return nil }
            return formatSleepCategory(value: categorySample.value)
        case .category:
            return nil
        case .workout:
            guard let workout = sample as? HKWorkout else { return nil }
            return formatWorkout(workout)
        }
    }

    private func formatExample(sample: HKSample, descriptor: Descriptor) -> String {
        let value = formatLatestValue(sample: sample, descriptor: descriptor) ?? "n/a"
        let source = sample.sourceRevision.source.name
        let time = sample.endDate.formatted(.dateTime.month().day().hour().minute())
        return "\(time) · \(value) · \(source)"
    }

    private func formatQuantity(_ quantity: HKQuantity, identifier: HKQuantityTypeIdentifier) -> String? {
        guard let unit = unit(for: identifier) else { return nil }
        let value = quantity.doubleValue(for: unit)

        switch identifier {
        case .stepCount, .flightsClimbed:
            return "\(Int(value.rounded()))"
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage:
            return String(format: "%.0f bpm", value)
        case .heartRateVariabilitySDNN, .heartRateRecoveryOneMinute:
            return String(format: "%.0f ms", value)
        case .activeEnergyBurned, .basalEnergyBurned:
            return String(format: "%.0f kcal", value)
        case .distanceWalkingRunning, .height:
            return String(format: "%.1f m", value)
        case .oxygenSaturation, .bodyFatPercentage:
            return String(format: "%.1f%%", value * 100)
        case .respiratoryRate:
            return String(format: "%.1f rpm", value)
        case .bodyMass, .leanBodyMass:
            return String(format: "%.1f kg", value)
        case .bodyTemperature, .appleSleepingWristTemperature:
            return String(format: "%.1f °C", value)
        case .bodyMassIndex:
            return String(format: "%.1f BMI", value)
        case .vo2Max:
            return String(format: "%.1f mL/kg·min", value)
        case .appleStandTime, .appleExerciseTime:
            return String(format: "%.0f min", value)
        default:
            return String(format: "%.2f", value)
        }
    }

    private func unit(for identifier: HKQuantityTypeIdentifier) -> HKUnit? {
        switch identifier {
        case .stepCount, .flightsClimbed:
            return .count()
        case .heartRate, .restingHeartRate, .walkingHeartRateAverage:
            return HKUnit.count().unitDivided(by: .minute())
        case .heartRateVariabilitySDNN, .heartRateRecoveryOneMinute:
            return .secondUnit(with: .milli)
        case .activeEnergyBurned, .basalEnergyBurned:
            return .kilocalorie()
        case .distanceWalkingRunning, .height:
            return .meter()
        case .oxygenSaturation, .bodyFatPercentage:
            return .percent()
        case .respiratoryRate:
            return HKUnit.count().unitDivided(by: .minute())
        case .bodyMass, .leanBodyMass:
            return .gramUnit(with: .kilo)
        case .bodyTemperature, .appleSleepingWristTemperature:
            return .degreeCelsius()
        case .bodyMassIndex:
            return .count()
        case .vo2Max:
            return HKUnit.literUnit(with: .milli).unitDivided(by: .gramUnit(with: .kilo)).unitDivided(by: .minute())
        case .appleStandTime, .appleExerciseTime:
            return .minute()
        default:
            return nil
        }
    }

    private func formatSleepCategory(value: Int) -> String {
        switch value {
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return "asleepREM"
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return "asleepDeep"
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            return "asleepCore"
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            return "awake"
        case HKCategoryValueSleepAnalysis.inBed.rawValue:
            return "inBed"
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            return "asleepUnspecified"
        default:
            return "raw=\(value)"
        }
    }

    private func formatWorkout(_ workout: HKWorkout) -> String {
        let activity = workoutActivityName(workout.workoutActivityType)
        let duration = "\(Int(workout.duration.rounded()))s"
        let energy = workout.totalEnergyBurned.map { String(format: "%.0f kcal", $0.doubleValue(for: .kilocalorie())) } ?? "-"
        let distance = workout.totalDistance.map { String(format: "%.0f m", $0.doubleValue(for: .meter())) } ?? "-"
        return "\(activity) · \(duration) · energy=\(energy) · dist=\(distance)"
    }

    private func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .yoga: return "yoga"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "strength_training"
        default:
            return String(describing: type)
                .replacingOccurrences(of: "HKWorkoutActivityType", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
