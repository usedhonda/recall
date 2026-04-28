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
    func upload(samples: [LocationSample], healthPayload: HealthPayload? = nil) async throws {
        guard !samples.isEmpty || healthPayload != nil else { return }

        let settings = await MainActor.run { AppSettings.shared }
        let serverURL = await MainActor.run { settings.telemetryServerURL }
        guard let token = KeychainHelper.shared.getToken(),
              !serverURL.isEmpty else { return }

        // Snapshot nowPlaying so background uploads carry the same context as
        // foreground sends (Cdx audit: previously only foreground sendLocation/
        // sendHealth attached `nowPlaying`, leaving background batches blind).
        let nowPlaying = await MainActor.run { TelemetryService.shared.nowPlayingManager.snapshot }

        let batch = TelemetrySampleBatch(
            samples: samples.map { sample in
                TelemetrySample(
                    id: sample.id.uuidString,
                    lat: sample.latitude,
                    lon: sample.longitude,
                    accuracy: sample.accuracy,
                    altitude: sample.altitude,
                    speed: sample.speed,
                    timestamp: sample.timestamp,
                    quality: sample.quality
                )
            },
            health2: healthPayload,
            nowPlaying: nowPlaying
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

    /// Upload health data only (no location samples) — used from background HKObserverQuery/timer.
    /// Carries the self-describing records (with measuredAt + source) under `health2`.
    @MainActor
    func uploadHealthOnly(_ payload: HealthPayload) async {
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

        ActivityLogger.shared.log(.telemetry, "Telemetry POST (bg): health2=[\(payload.recordsLogSummary())]")

        do {
            try await uploadImmediate(
                samples: [],
                healthPayload: payload,
                serverURL: settings.telemetryServerURL,
                token: token
            )
            TelemetryUploader.log("healthOnly OK")
        } catch {
            TelemetryUploader.log("healthOnly FAIL \(error.localizedDescription) -> laneB")
            do {
                try await upload(samples: [], healthPayload: payload)
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
        let health = await queryHealthForBackground()

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
                healthPayload: health,
                serverURL: settings.telemetryServerURL,
                token: token
            )
            TelemetryUploader.log("laneA OK samples=\(samples.count) health=\(health != nil)")
            lastUploadTime = Date()
            lastUploadResult = "success"
        } catch {
            let detail = error.localizedDescription
            TelemetryUploader.log("laneA FAIL \(detail) -> laneB")
            lastUploadResult = "error: \(detail)"
            do {
                try await upload(samples: samples, healthPayload: health)
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
        healthPayload: HealthPayload? = nil,
        serverURL: String,
        token: String
    ) async throws {
        // Same nowPlaying snapshot rule as `upload(samples:healthPayload:)`.
        let nowPlaying = await MainActor.run { TelemetryService.shared.nowPlayingManager.snapshot }

        let batch = TelemetrySampleBatch(
            samples: samples.map { sample in
                TelemetrySample(
                    id: sample.id.uuidString,
                    lat: sample.latitude,
                    lon: sample.longitude,
                    accuracy: sample.accuracy,
                    altitude: sample.altitude,
                    speed: sample.speed,
                    timestamp: sample.timestamp,
                    quality: sample.quality
                )
            },
            health2: healthPayload,
            nowPlaying: nowPlaying
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

    /// Query HealthKit data for background upload piggyback.
    /// Uses the shared HealthKitManager (which has been authorized) for consistent behavior.
    @MainActor
    private func queryHealthForBackground() async -> HealthPayload? {
        let manager = TelemetryService.shared.healthManager
        guard manager.isEnabled, manager.isAuthorized else { return nil }
        guard HKHealthStore.isHealthDataAvailable() else { return nil }

        let now = Date()
        let payload = await manager.aggregateHealthPayload(from: now.addingTimeInterval(-3600), to: now)

        let hasData = !payload.records.isEmpty
            || payload.sleep != nil
            || (payload.workouts?.isEmpty == false)
        return hasData ? payload : nil
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
