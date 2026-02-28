import Foundation
import HealthKit
import UIKit

/// Background session identifier for telemetry uploads
private let backgroundSessionIdentifier = "com.recall.telemetry-upload"

/// Handles background upload of telemetry data (location + health) using URLSession
final class TelemetryUploader: NSObject {
    static let shared = TelemetryUploader()

    var backgroundCompletionHandler: (() -> Void)?

    // MARK: - Upload Statistics

    @MainActor
    private(set) var lastUploadTime: Date?

    @MainActor
    private(set) var lastUploadResult: String?

    @MainActor
    private(set) var activeTaskCount: Int = 0

    // Background session for uploads
    private lazy var backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsConstrainedNetworkAccess = true
        config.allowsExpensiveNetworkAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    // Immediate session for real-time uploads (non-background)
    private lazy var immediateSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    @MainActor
    private var isTriggerUploadRunning = false

    // MARK: - Persistent debug log

    private static let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("telemetry_upload.log")
    }()

    private static let logDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(_ message: String) {
        let line = "\(logDateFormatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
        print("[TelemetryUpload] \(message)")
    }

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Upload location samples via background URLSession (Lane B fallback)
    func upload(samples: [LocationSample], health: HealthSummary? = nil) async throws {
        guard !samples.isEmpty || health != nil else { return }

        let settings = await MainActor.run { AppSettings.shared }
        let serverURL = await MainActor.run { settings.telemetryServerURL }
        guard let token = KeychainHelper.shared.getToken(),
              !serverURL.isEmpty else { return }

        let batch = TelemetrySampleBatch(
            samples: samples.map { sample in
                TelemetrySample(
                    id: sample.id.uuidString,
                    lat: sample.latitude,
                    lon: sample.longitude,
                    accuracy: sample.accuracy,
                    altitude: sample.altitude,
                    speed: sample.speed,
                    timestamp: sample.timestamp
                )
            },
            health: health
        )

        let url = URL(string: "\(serverURL)/api/telemetry")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let bodyData = try encoder.encode(batch)

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + ".json")
        try bodyData.write(to: tempFile)

        let task = backgroundSession.uploadTask(with: urlRequest, fromFile: tempFile)
        task.resume()

        print("[TelemetryUploader] Started background upload of \(samples.count) samples")
    }

    /// Upload health data only (no location samples) — used from background HKObserverQuery/timer
    @MainActor
    func uploadHealthOnly(_ summary: HealthSummary) async {
        let settings = AppSettings.shared
        guard !settings.telemetryServerURL.isEmpty,
              let token = KeychainHelper.shared.getToken() else { return }

        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask {
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
                taskId = .invalid
            }
        }

        do {
            try await uploadImmediate(
                samples: [],
                health: summary,
                serverURL: settings.telemetryServerURL,
                token: token
            )
            TelemetryUploader.log("healthOnly OK")
        } catch {
            TelemetryUploader.log("healthOnly FAIL \(error.localizedDescription) -> laneB")
            do {
                try await upload(samples: [], health: summary)
            } catch {
                TelemetryUploader.log("healthOnly laneB FAIL \(error.localizedDescription)")
            }
        }

        if taskId != .invalid {
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    /// Trigger upload of pending samples (called from LocationManager / TelemetryService)
    /// Hybrid: immediate upload first, falls back to background URLSession on failure
    @MainActor
    func triggerUpload() async {
        guard !isTriggerUploadRunning else { return }
        isTriggerUploadRunning = true
        defer { isTriggerUploadRunning = false }

        let samples = await LocationQueue.shared.drain(max: 50)
        guard !samples.isEmpty else { return }

        let appState = UIApplication.shared.applicationState
        let stateLabel = appState == .active ? "fg" : (appState == .background ? "bg" : "inactive")
        TelemetryUploader.log("triggerUpload samples=\(samples.count) state=\(stateLabel)")

        let settings = AppSettings.shared
        guard !settings.telemetryServerURL.isEmpty,
              let token = KeychainHelper.shared.getToken() else {
            for sample in samples {
                await LocationQueue.shared.enqueue(sample)
            }
            TelemetryUploader.log("triggerUpload NO_CONFIG re-queued=\(samples.count)")
            return
        }

        // Query health data to piggyback on location upload
        let healthSummary = await queryHealthForBackground()

        // Lane A: immediate upload with beginBackgroundTask
        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask {
            self.immediateSession.getAllTasks { tasks in
                tasks.forEach { $0.cancel() }
            }
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
                taskId = .invalid
            }
        }

        do {
            try await uploadImmediate(
                samples: samples,
                health: healthSummary,
                serverURL: settings.telemetryServerURL,
                token: token
            )
            TelemetryUploader.log("laneA OK samples=\(samples.count) health=\(healthSummary != nil)")
            lastUploadTime = Date()
            lastUploadResult = "success"
        } catch {
            let detail = error.localizedDescription
            TelemetryUploader.log("laneA FAIL \(detail) -> laneB")
            lastUploadResult = "error: \(detail)"
            do {
                try await upload(samples: samples, health: healthSummary)
                TelemetryUploader.log("laneB OK samples=\(samples.count)")
            } catch {
                for sample in samples {
                    await LocationQueue.shared.enqueue(sample)
                }
                let detail2 = error.localizedDescription
                TelemetryUploader.log("laneB FAIL \(detail2) re-queued=\(samples.count)")
                lastUploadResult = "failed: \(detail2)"
            }
        }

        if taskId != .invalid {
            UIApplication.shared.endBackgroundTask(taskId)
        }
    }

    /// Upload samples immediately using default URLSession (Lane A)
    private func uploadImmediate(
        samples: [LocationSample],
        health: HealthSummary? = nil,
        serverURL: String,
        token: String
    ) async throws {
        let batch = TelemetrySampleBatch(
            samples: samples.map { sample in
                TelemetrySample(
                    id: sample.id.uuidString,
                    lat: sample.latitude,
                    lon: sample.longitude,
                    accuracy: sample.accuracy,
                    altitude: sample.altitude,
                    speed: sample.speed,
                    timestamp: sample.timestamp
                )
            },
            health: health
        )

        let url = URL(string: "\(serverURL)/api/telemetry")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        urlRequest.httpBody = try encoder.encode(batch)

        let (_, response) = try await immediateSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    /// Query HealthKit data for background upload piggyback
    @MainActor
    private func queryHealthForBackground() async -> HealthSummary? {
        guard AppSettings.shared.healthEnabled else { return nil }
        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        let store = HKHealthStore()
        let now = Date()
        let start = now.addingTimeInterval(-3600)

        var summary = HealthSummary(periodStart: start, periodEnd: now)

        // Steps (today)
        if let type = HKQuantityType.quantityType(forIdentifier: .stepCount) {
            let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.startOfDay(for: now), end: now)
            summary.steps = await queryCumulativeSum(store: store, type: type, unit: .count(), predicate: predicate).map { Int($0) }
        }

        // Heart rate (last hour)
        if let type = HKQuantityType.quantityType(forIdentifier: .heartRate) {
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            let unit = HKUnit.count().unitDivided(by: .minute())
            if let stats = await queryStats(store: store, type: type, unit: unit, predicate: predicate, options: [.discreteAverage, .discreteMin, .discreteMax]) {
                summary.heartRateAvg = stats.avg
                summary.heartRateMin = stats.min
                summary.heartRateMax = stats.max
            }
        }

        // Active energy (today)
        if let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
            let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.startOfDay(for: now), end: now)
            summary.activeEnergyKcal = await queryCumulativeSum(store: store, type: type, unit: .kilocalorie(), predicate: predicate)
        }

        // Distance (today)
        if let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
            let predicate = HKQuery.predicateForSamples(withStart: Calendar.current.startOfDay(for: now), end: now)
            summary.distanceMeters = await queryCumulativeSum(store: store, type: type, unit: .meter(), predicate: predicate)
        }

        // SpO2
        if let type = HKQuantityType.quantityType(forIdentifier: .oxygenSaturation) {
            let predicate = HKQuery.predicateForSamples(withStart: start, end: now)
            if let val = await queryLatest(store: store, type: type, unit: .percent(), predicate: predicate) {
                summary.bloodOxygenPercent = val * 100
            }
        }

        let hasData = summary.steps != nil || summary.heartRateAvg != nil || summary.activeEnergyKcal != nil
        return hasData ? summary : nil
    }

    // MARK: - Background HealthKit Query Helpers

    private func queryCumulativeSum(store: HKHealthStore, type: HKQuantityType, unit: HKUnit, predicate: NSPredicate) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: .cumulativeSum) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    private func queryStats(store: HKHealthStore, type: HKQuantityType, unit: HKUnit, predicate: NSPredicate, options: HKStatisticsOptions) async -> (avg: Double, min: Double, max: Double)? {
        await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate, options: options) { _, stats, _ in
                guard let avg = stats?.averageQuantity()?.doubleValue(for: unit),
                      let min = stats?.minimumQuantity()?.doubleValue(for: unit),
                      let max = stats?.maximumQuantity()?.doubleValue(for: unit) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (avg, min, max))
            }
            store.execute(query)
        }
    }

    private func queryLatest(store: HKHealthStore, type: HKQuantityType, unit: HKUnit, predicate: NSPredicate) async -> Double? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                continuation.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Process completed background session
    func handleBackgroundSession(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = backgroundSession.configuration
    }

    @MainActor
    func updateActiveTaskCount() async {
        let tasks = await backgroundSession.allTasks
        activeTaskCount = tasks.count
    }
}

// MARK: - URLSessionDelegate

extension TelemetryUploader: URLSessionDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("[TelemetryUploader] Upload failed: \(error)")
            Task { @MainActor in
                lastUploadResult = "error: \(error.localizedDescription)"
            }
        } else {
            print("[TelemetryUploader] Upload completed successfully")
            Task { @MainActor in
                lastUploadTime = Date()
                lastUploadResult = "success"
            }
        }

        Task { @MainActor in
            await updateActiveTaskCount()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            let response = try JSONDecoder().decode(TelemetryResponse.self, from: data)
            print("[TelemetryUploader] Server acknowledged \(response.received) samples")
        } catch {
            // Ignore parse errors
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }
}
