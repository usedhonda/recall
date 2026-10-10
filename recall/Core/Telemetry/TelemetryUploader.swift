import Foundation
import HealthKit
import UIKit

/// Background session identifier for telemetry uploads
private let backgroundSessionIdentifier = "com.recall.telemetry-upload"

/// Handles background upload of telemetry data (location + health) using URLSession
final class TelemetryUploader: NSObject {
    static let shared = TelemetryUploader()
    enum SchedulingFailure: Error { case legacyRouteDisabled }

    var backgroundCompletionHandler: (() -> Void)?
    /// Set by HealthKitManager to reconcile a durable background ACK with the
    /// original Health payload identity. Scheduling never invokes this hook.
    var healthAcknowledgmentHandler: (@MainActor (String, String, HealthUploadSource) -> Bool)?

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
        config.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: config)
    }()

    private let callbackState = TelemetryCallbackState()

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
    func upload(samples: [LocationSample], healthPayload: HealthPayload? = nil,
                nowPlayingSnapshot: NowPlayingSnapshot?) async throws {
        guard !samples.isEmpty || healthPayload != nil else { return }
        guard await canUploadTelemetry(samples: samples, healthPayload: healthPayload) else {
            Self.log("network policy: telemetry laneB skipped")
            throw URLError(.notConnectedToInternet)
        }

        let settings = await MainActor.run { AppSettings.shared }
        let serverURL = await MainActor.run { settings.telemetryServerURL }
        guard let token = KeychainHelper.shared.getToken(),
              !serverURL.isEmpty else { throw URLError(.badURL) }

        // Snapshot nowPlaying so background uploads carry the same context as
        // foreground sends (Cdx audit: previously only foreground sendLocation/
        // sendHealth attached `nowPlaying`, leaving background batches blind).
        let nowPlaying = await legacyNowPlaying(nowPlayingSnapshot)

        let batch = TelemetrySampleBatch(
            samples: samples.map { TelemetrySample(from: $0) },
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

        let ledger = TelemetryBatchLedger.shared
        let existing: TelemetryBatchLedger.Batch?
        if samples.isEmpty, let healthPayload {
            existing = await ledger.pendingHealth(deliveryID: healthPayload.deliveryID.uuidString)
        } else {
            existing = await ledger.pendingBatch(sampleIDs: samples.map(\.id), healthIncluded: healthPayload != nil)
        }
        let overlapsPending = await ledger.hasPendingOverlap(sampleIDs: samples.map(\.id))
        if existing == nil && overlapsPending {
            Self.log("telemetry batch overlaps pending ownership; retaining IDs")
            return
        }
        if let active = existing,
           active.taskDescription != nil {
            Self.log("telemetry batch already in flight; retaining same sample IDs")
            return
        }

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let rowID = existing?.id ?? UUID()
        let reservationRoute: HubRecallRoute = samples.isEmpty ? .healthSnapshot : .gpsDelivery
        let routeEnabled = await MainActor.run { HubDeliveryService.shared.isEnabled(reservationRoute) }
        let tempFile: URL
        if let existing { tempFile = try await ledger.ensureRequestFile(for: existing) }
        else { tempFile = docs.appendingPathComponent("telemetry-batch-\(rowID.uuidString).json") }
        let reservedBytes = existing == nil ? bodyData.count : try Data(contentsOf: tempFile).count
        if routeEnabled {
            try await HubDeliveryService.shared.reserveQueueBytes(route: reservationRoute,
                key: "telemetry-batch-\(rowID.uuidString)", bytes: Int64(reservedBytes + 2048))
        }
        let row: TelemetryBatchLedger.Batch
        do {
            if let existing { row = existing }
            else {
                try bodyData.write(to: tempFile, options: .atomic)
                row = try await ledger.create(id: rowID, sampleIDs: samples.map(\.id), healthIncluded: healthPayload != nil,
                    healthDeliveryID: healthPayload?.deliveryID.uuidString,
                    healthFingerprint: healthPayload.map(HealthKitManager.fingerprint),
                    healthCollectedAt: healthPayload?.collectedAt,
                    nowPlayingIncluded: nowPlaying != nil, requestFile: tempFile)
            }
        } catch {
            if existing == nil {
                try? FileManager.default.removeItem(at: tempFile)
                if routeEnabled {
                    try? await HubDeliveryService.shared.reserveQueueBytes(route: reservationRoute,
                        key: "telemetry-batch-\(rowID.uuidString)", bytes: 0)
                }
            }
            throw error
        }
        let scheduled = try await Self.scheduleLegacyBatch(row, disabled: await Self.disabledLegacyRoutes()) {
            let task = self.backgroundSession.uploadTask(with: urlRequest, fromFile: tempFile)
            task.taskDescription = row.id.uuidString
            try await ledger.setTaskDescription(row.id.uuidString, for: row.id)
            task.resume()
        }
        guard scheduled else {
            Self.log("telemetry batch retained: legacy route disabled or unknown")
            throw SchedulingFailure.legacyRouteDisabled
        }

        print("[TelemetryUploader] Started background upload of \(samples.count) samples")
    }

    /// Upload health data only (no location samples) — used from background HKObserverQuery/timer.
    /// Carries the self-describing records (with measuredAt + source) under `health2`.
    @MainActor
    func uploadHealthOnly(_ payload: HealthPayload) async -> HealthUploadOutcome {
        let nowPlayingSnapshot = TelemetryService.shared.nowPlayingManager.snapshot
        await reconcileBackgroundTasks()
        await retryPendingHealthBatches()
        do {
            let hubExternalID = try await HubTelemetryAdmission.admit(
                route: .healthSnapshot,
                observationID: payload.deliveryID.uuidString,
                occurredAt: payload.collectedAt,
                payload: payload
            )
            if let snapshot = nowPlayingSnapshot {
                do {
                    _ = try await HubTelemetryAdmission.admit(route: .nowPlaying,
                                                              observationID: snapshot.deliveryID.uuidString,
                                                              occurredAt: snapshot.timestamp,
                                                              payload: snapshot)
                } catch {
                    TelemetryUploader.log("nowPlaying Hub admission failed")
                }
            }
            if !HubTelemetryAdmission.legacyAllowed(.healthSnapshot) {
                guard let hubExternalID,
                      try await HubDeliveryService.shared.isAcknowledged(externalID: hubExternalID) else {
                    TelemetryUploader.log("health Hub admission pending")
                    guard let hubExternalID else {
                        return .failed(deliveryID: payload.deliveryID, message: "Hub admission pending without external ID")
                    }
                    let binding = await TelemetryService.shared.registerHubHealthPending(
                        payload, fingerprint: HealthKitManager.fingerprint(payload), externalID: hubExternalID)
                    if case .error = binding {
                        return .failed(deliveryID: payload.deliveryID, message: "Hub pending state persistence failed")
                    }
                    return .scheduled(deliveryID: payload.deliveryID)
                }
                TelemetryUploader.log("health Hub store-only ACK")
                return .acknowledged(deliveryID: payload.deliveryID, source: .hub)
            }
        } catch {
            TelemetryUploader.log("health Hub admission failed")
            return .failed(deliveryID: payload.deliveryID, message: "Hub admission failed")
        }
        guard ConnectivityMonitor.shared.canSendHealth else {
            TelemetryUploader.log("network policy: healthOnly skipped")
            return .failed(deliveryID: payload.deliveryID, message: "waiting for WiFi (health wifi-only)")
        }
        let settings = AppSettings.shared
        guard !settings.telemetryServerURL.isEmpty,
              let token = KeychainHelper.shared.getToken() else {
            return .failed(deliveryID: payload.deliveryID, message: "not configured")
        }

        var taskId: UIBackgroundTaskIdentifier = .invalid
        taskId = UIApplication.shared.beginBackgroundTask {
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
                taskId = .invalid
            }
        }
        defer {
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
                token: token,
                nowPlayingSnapshot: nowPlayingSnapshot
            )
            TelemetryUploader.log("healthOnly OK")
            return .acknowledged(deliveryID: payload.deliveryID, source: .legacy)
        } catch {
            TelemetryUploader.log("healthOnly FAIL \(error.localizedDescription) -> laneB")
            do {
                try await upload(samples: [], healthPayload: payload,
                                 nowPlayingSnapshot: nowPlayingSnapshot)
            } catch {
                TelemetryUploader.log("healthOnly laneB FAIL \(error.localizedDescription)")
                return .failed(deliveryID: payload.deliveryID, message: error.localizedDescription)
            }
            return .scheduled(deliveryID: payload.deliveryID)
        }
    }

    /// Trigger upload of pending samples (called from LocationManager / TelemetryService)
    /// Hybrid: immediate upload first, falls back to background URLSession on failure
    @MainActor
    func triggerUpload() async {
        guard ConnectivityMonitor.shared.canSendLocation else {
            TelemetryUploader.log("network policy: triggerUpload skipped before drain")
            return
        }
        guard !isTriggerUploadRunning else { return }
        isTriggerUploadRunning = true
        defer { isTriggerUploadRunning = false }

        await reconcileBackgroundTasks()
        await retryPendingHealthBatches()
        let samples = await LocationQueue.shared.peek(max: 50)
        guard !samples.isEmpty else { return }
        let nowPlayingSnapshot = TelemetryService.shared.nowPlayingManager.snapshot

        var hubIDs: [UUID: String] = [:]
        var hubAcked = true
        do {
            for sample in samples {
                if let externalID = try await HubTelemetryAdmission.admit(
                    route: .gpsDelivery,
                    observationID: sample.id.uuidString,
                    occurredAt: sample.timestamp,
                    payload: TelemetrySample(from: sample)
                ) { hubIDs[sample.id] = externalID }
            }
            for externalID in hubIDs.values {
                let acknowledged = try await HubDeliveryService.shared.isAcknowledged(externalID: externalID)
                hubAcked = hubAcked && acknowledged
            }
            if !hubAcked { TelemetryUploader.log("GPS Hub admission pending samples=\(samples.count)") }
        } catch {
            TelemetryUploader.log("GPS Hub admission failed samples=\(samples.count)")
            return
        }

        let appState = UIApplication.shared.applicationState
        let stateLabel = appState == .active ? "fg" : (appState == .background ? "bg" : "inactive")
        TelemetryUploader.log("triggerUpload samples=\(samples.count) state=\(stateLabel)")

        let settings = AppSettings.shared
        let hubEnabled = await MainActor.run { HubDeliveryService.shared.isEnabled(.gpsDelivery) }
        let legacyAllowed = HubTelemetryAdmission.legacyAllowed(.gpsDelivery)
        if !legacyAllowed {
            guard hubIDs.count == samples.count, hubAcked else { return }
            if hubIDs.isEmpty || hubAcked { await LocationQueue.shared.remove(ids: Set(samples.map(\.id))) }
            TelemetryUploader.log("GPS Hub store-only ACK samples=\(samples.count)")
            return
        }
        guard !settings.telemetryServerURL.isEmpty,
              let token = KeychainHelper.shared.getToken() else {
            TelemetryUploader.log("triggerUpload NO_CONFIG re-queued=\(samples.count)")
            return
        }
        var legacySamples: [LocationSample] = []
        for sample in samples where !(await LocationQueue.shared.legacyDelivered(sample.id)) {
            legacySamples.append(sample)
        }
        if legacySamples.isEmpty {
            if hubIDs.isEmpty && !hubEnabled {
                await LocationQueue.shared.remove(ids: Set(samples.map(\.id)))
                return
            }
            if hubEnabled && hubIDs.count != samples.count { return }
            if !hubIDs.isEmpty && !hubAcked { return }
            if !hubIDs.isEmpty && hubAcked {
                await LocationQueue.shared.remove(ids: Set(samples.map(\.id)))
            }
            return
        }

        // Query health data to piggyback on location upload
        var health = await queryHealthForBackground()
        if let healthPayload = health {
            do {
                let externalID = try await HubTelemetryAdmission.admit(
                    route: .healthSnapshot,
                    observationID: healthPayload.deliveryID.uuidString,
                    occurredAt: healthPayload.collectedAt,
                    payload: healthPayload
                )
                if !HubTelemetryAdmission.legacyAllowed(.healthSnapshot) {
                    // The durable Health outbox continues independently of this GPS batch.
                    _ = externalID
                    health = nil
                }
            } catch {
                TelemetryUploader.log("health Hub admission failed")
                health = nil
            }
        }
        if let snapshot = nowPlayingSnapshot {
            do {
                _ = try await HubTelemetryAdmission.admit(route: .nowPlaying,
                                                          observationID: snapshot.deliveryID.uuidString,
                                                          occurredAt: snapshot.timestamp,
                                                          payload: snapshot)
            } catch {
                TelemetryUploader.log("nowPlaying Hub admission failed")
            }
        }
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
        defer {
            if taskId != .invalid {
                UIApplication.shared.endBackgroundTask(taskId)
                taskId = .invalid
            }
        }

        do {
            try await uploadImmediate(
                samples: legacySamples,
                healthPayload: health,
                serverURL: settings.telemetryServerURL,
                token: token,
                nowPlayingSnapshot: nowPlayingSnapshot
            )
            guard await LocationQueue.shared.markLegacyDelivered(Set(legacySamples.map(\.id))) else {
                TelemetryUploader.log("legacy delivery recorded failure; queue retained")
                return
            }
            TelemetryUploader.log("laneA OK samples=\(legacySamples.count) health=\(health != nil)")
            // Legacy success is durable, but queue ownership remains until the
            // required Hub receipt is present. The callback/reconciliation path
            // releases this same set when ACK arrives.
            await releaseLocationIfHubAcknowledged(samples.map(\.id))
            lastUploadTime = Date()
            lastUploadResult = "success"
        } catch {
            let detail = error.localizedDescription
            TelemetryUploader.log("laneA FAIL \(detail) -> laneB")
            lastUploadResult = "error: \(detail)"
            do {
                try await upload(samples: legacySamples, healthPayload: health,
                                 nowPlayingSnapshot: nowPlayingSnapshot)
                // URLSession scheduling is not delivery. The durable callback
                // validates the response and owns both legacy marking and
                // Hub-gated queue release.
                TelemetryUploader.log("laneB scheduled samples=\(legacySamples.count); awaiting callback")
            } catch {
                let detail2 = error.localizedDescription
                TelemetryUploader.log("laneB FAIL \(detail2) re-queued=\(samples.count)")
                lastUploadResult = "failed: \(detail2)"
            }
        }

    }

    /// Upload samples immediately using default URLSession (Lane A)
    private func uploadImmediate(
        samples: [LocationSample],
        healthPayload: HealthPayload? = nil,
        serverURL: String,
        token: String,
        nowPlayingSnapshot: NowPlayingSnapshot?
    ) async throws -> (data: Data, statusCode: Int) {
        guard await canUploadTelemetry(samples: samples, healthPayload: healthPayload) else {
            TelemetryUploader.log("network policy: telemetry immediate skipped")
            throw URLError(.notConnectedToInternet)
        }
        // Same nowPlaying snapshot rule as `upload(samples:healthPayload:)`.
        let nowPlaying = await legacyNowPlaying(nowPlayingSnapshot)

        let batch = TelemetrySampleBatch(
            samples: samples.map { TelemetrySample(from: $0) },
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

        let (data, response) = try await immediateSession.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let acknowledged = try TelemetryAcknowledgment.validate(data: data, statusCode: httpResponse.statusCode,
                                                               requiresHealth: healthPayload != nil)
        if !samples.isEmpty && !Self.accepted(acknowledged, sampleIDs: samples.map(\.id)) {
            throw URLError(.cannotParseResponse)
        }
        return (data, httpResponse.statusCode)
    }

    private func legacyNowPlaying(_ snapshot: NowPlayingSnapshot?) async -> NowPlayingSnapshot? {
        return await MainActor.run {
            NowPlayingTelemetryProjection.legacySnapshot(
                snapshot,
                streamEnabled: TelemetryService.shared.nowPlayingManager.isEnabled,
                legacyAllowed: HubTelemetryAdmission.legacyAllowed(.nowPlaying)
            )
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

    @MainActor
    private func canUploadTelemetry(samples: [LocationSample], healthPayload: HealthPayload?) -> Bool {
        if !samples.isEmpty {
            return ConnectivityMonitor.shared.canSendLocation
        }
        if healthPayload != nil {
            return ConnectivityMonitor.shared.canSendHealth
        }
        return true
    }

    /// Process completed background session
    func handleBackgroundSession(completionHandler: @escaping () -> Void) {
        backgroundCompletionHandler = completionHandler
        _ = backgroundSession.configuration
        Task { await reconcileBackgroundTasks(); await retryPendingHealthBatches() }
    }

    @MainActor
    func updateActiveTaskCount() async {
        let tasks = await backgroundSession.allTasks
        activeTaskCount = tasks.count
        await reconcileBackgroundTasks(tasks: tasks)
    }

    private func reconcileBackgroundTasks(tasks: [URLSessionTask]? = nil) async {
        guard !callbackState.isProcessing else { return }
        let active: [URLSessionTask]
        if let tasks { active = tasks } else { active = await backgroundSession.allTasks }
        let descriptions = Set(active.compactMap(\.taskDescription))
        for row in await TelemetryBatchLedger.shared.pending()
            where row.taskDescription != nil && !descriptions.contains(row.taskDescription!) {
            try? await TelemetryBatchLedger.shared.clearTaskDescription(row.id)
        }
    }

    func reconcileHubHealthAcknowledgments() async {
        // Hub-only rows do not require legacy URL/token/network state.
        for row in await TelemetryBatchLedger.shared.pending() {
            guard row.sampleIDs.isEmpty, let externalID = row.healthHubExternalID else { continue }
            if (try? await HubDeliveryService.shared.isAcknowledged(externalID: externalID)) == true {
                do {
                    _ = try await TelemetryBatchLedger.shared.acknowledgeHubHealth(externalID: externalID) { [self] healthID, fingerprint in
                        guard let handler = self.healthAcknowledgmentHandler else { return false }
                        return handler(healthID, fingerprint, .hub)
                    }
                } catch { TelemetryUploader.log("Hub Health acknowledgment state persistence failed; retained for reconciliation") }
            }
        }
    }

    private func retryPendingHealthBatches() async {
        guard !callbackState.isProcessing else { return }
        await reconcileHubHealthAcknowledgments()
        let settings = await MainActor.run { AppSettings.shared }
        guard !settings.telemetryServerURL.isEmpty, let token = KeychainHelper.shared.getToken() else { return }
        for row in await TelemetryBatchLedger.shared.pending() where row.taskDescription == nil {
            if row.sampleIDs.isEmpty, row.healthHubExternalID != nil { continue }
            let allowed = await MainActor.run {
                row.sampleIDs.isEmpty ? ConnectivityMonitor.shared.canSendHealth : ConnectivityMonitor.shared.canSendLocation
            }
            guard allowed else { continue }
            let disabledRoutes = await Self.disabledLegacyRoutes()
            guard Self.legacyRoutesAllowed(row, disabled: disabledRoutes) else {
                TelemetryUploader.log("frozen batch retained: legacy route disabled or unknown")
                continue
            }
            let route: HubRecallRoute = row.sampleIDs.isEmpty ? .healthSnapshot : .gpsDelivery
            do {
                let file = try await TelemetryBatchLedger.shared.ensureRequestFile(for: row)
                guard let url = URL(string: "\(settings.telemetryServerURL)/api/telemetry") else { continue }
                var request = URLRequest(url: url); request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("recall-ios/1.0", forHTTPHeaderField: "User-Agent")
                if await MainActor.run(body: { HubDeliveryService.shared.isEnabled(route) }) {
                    try await HubDeliveryService.shared.reserveQueueBytes(route: route,
                        key: "telemetry-batch-\(row.id.uuidString)", bytes: Int64(try Data(contentsOf: file).count + 2048))
                }
                _ = try await Self.scheduleLegacyBatch(row, disabled: await Self.disabledLegacyRoutes()) {
                    let task = self.backgroundSession.uploadTask(with: request, fromFile: file)
                    task.taskDescription = row.id.uuidString
                    try await TelemetryBatchLedger.shared.setTaskDescription(row.id.uuidString, for: row.id)
                    task.resume()
                }
            } catch { TelemetryUploader.log("health batch retry unavailable; frozen file retained") }
        }
    }
}

// MARK: - URLSessionDelegate

extension TelemetryUploader: URLSessionDelegate, URLSessionDataDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = callbackState.beginCompletion(task.taskIdentifier)
        Task { [self] in
            if let error {
                if let id = UUID(uuidString: task.taskDescription ?? "") {
                    try? await TelemetryBatchLedger.shared.clearTaskDescription(id)
                }
                await MainActor.run { self.lastUploadResult = "error: \(error.localizedDescription)" }
            } else {
                await finishBackgroundBatch(task: task, data: body,
                    statusCode: (task.response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            callbackState.endCompletion()
            await finishSessionIfReady()
            await updateActiveTaskCount()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        callbackState.append(data, taskID: dataTask.taskIdentifier)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        callbackState.finishEvents()
        Task { await finishSessionIfReady() }
    }

    @MainActor
    private func finishSessionIfReady() {
        guard backgroundCompletionHandler != nil, callbackState.consumeFinished() else { return }
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }

    private func finishBackgroundBatch(task: URLSessionTask, data: Data, statusCode: Int) async {
        guard let value = task.taskDescription,
              let id = UUID(uuidString: value),
              let row = await TelemetryBatchLedger.shared.batch(id: id) else { return }
        do {
            let acknowledged = try TelemetryAcknowledgment.validate(data: data, statusCode: statusCode,
                requiresHealth: row.healthIncluded && row.sampleIDs.isEmpty)
            let gpsAccepted = row.sampleIDs.isEmpty || row.locationDelivered || Self.accepted(acknowledged, sampleIDs: row.sampleIDs)
            if !gpsAccepted {
                throw URLError(.cannotParseResponse)
            }
            guard let pending = await TelemetryBatchLedger.shared.batch(id: id) else { return }
            if gpsAccepted && !pending.locationDelivered && !pending.sampleIDs.isEmpty {
                guard await LocationQueue.shared.markLegacyDelivered(Set(pending.sampleIDs)) else {
                    throw URLError(.cannotWriteToFile)
                }
            }
            let healthIdentityApplied: Bool
            if pending.healthIncluded && acknowledged.healthReceived == true {
                guard let healthID = pending.healthDeliveryID, let fingerprint = pending.healthFingerprint,
                      let handler = self.healthAcknowledgmentHandler else { throw URLError(.cannotParseResponse) }
                await MainActor.run { handler(healthID, fingerprint, .legacy) }
                healthIdentityApplied = true
            } else { healthIdentityApplied = !pending.healthIncluded }
            let healthAccepted = healthIdentityApplied
            guard let delivered = try await TelemetryBatchLedger.shared.recordOutcome(id, location: gpsAccepted, health: healthAccepted) else { return }
            let reservationRoute: HubRecallRoute = delivered.sampleIDs.isEmpty ? .healthSnapshot : .gpsDelivery
            let reservationEnabled = await MainActor.run { HubDeliveryService.shared.isEnabled(reservationRoute) }
            if delivered.state == .delivered && reservationEnabled {
                try? await HubDeliveryService.shared.reserveQueueBytes(route: reservationRoute,
                    key: "telemetry-batch-\(delivered.id.uuidString)", bytes: 0)
            }
            if delivered.state == .pending { try await TelemetryBatchLedger.shared.clearTaskDescription(id) }
            if gpsAccepted && !delivered.sampleIDs.isEmpty {
                await releaseLocationIfHubAcknowledged(delivered.sampleIDs)
            }
            print("[TelemetryUploader] Upload callback accepted GPS=\(gpsAccepted) Health=\(healthAccepted)")
            await MainActor.run { self.lastUploadTime = Date(); self.lastUploadResult = delivered.state == .delivered ? "success" : "partial" }
        } catch {
            try? await TelemetryBatchLedger.shared.clearTaskDescription(id)
            await MainActor.run { self.lastUploadResult = "error: \(error.localizedDescription)" }
        }
    }

    private func releaseLocationIfHubAcknowledged(_ ids: [UUID]) async {
        let samples = await LocationQueue.shared.samples(ids: Set(ids))
        let target = samples.filter { ids.contains($0.id) }
        guard !target.isEmpty else { return }
        let hubEnabled = await MainActor.run { HubDeliveryService.shared.isEnabled(.gpsDelivery) }
        if !hubEnabled {
            _ = await LocationQueue.shared.remove(ids: Set(ids))
            return
        }
        var allAcked = true
        for sample in target {
            do {
                let external = try await HubTelemetryAdmission.admit(route: .gpsDelivery,
                    observationID: sample.id.uuidString, occurredAt: sample.timestamp,
                    payload: TelemetrySample(from: sample))
                guard let external else { allAcked = false; continue }
                if !(try await HubDeliveryService.shared.isAcknowledged(externalID: external)) { allAcked = false }
            } catch { allAcked = false }
        }
        if allAcked { _ = await LocationQueue.shared.remove(ids: Set(target.map(\.id))) }
    }

    static func accepted(_ response: TelemetryResponse, sampleIDs: [UUID]) -> Bool {
        if let acknowledgedIDs = response.acknowledgedIDs {
            return Set(acknowledgedIDs) == Set(sampleIDs.map(\.uuidString))
        }
        // Legacy gateway responses only report newly stored IDs. This proves
        // an initial full batch, but a duplicate retry with received=0 remains
        // intentionally retryable until the additive ID field is deployed.
        return response.received == sampleIDs.count
    }

    static func legacyRoutesAllowed(_ row: TelemetryBatchLedger.Batch, disabled: Set<String>) -> Bool {
        // Old frozen rows lack NowPlaying membership. They may retry only when
        // every possibly contained lane is still permitted; never infer absence.
        guard row.routeMetadataKnown else {
            return Set([HubRecallRoute.gpsDelivery, .healthSnapshot, .nowPlaying].map(\.rawValue)).isDisjoint(with: disabled)
        }
        if row.sampleIDs.isEmpty {
            if disabled.contains(HubRecallRoute.healthSnapshot.rawValue) { return false }
            return !row.nowPlayingIncluded || !disabled.contains(HubRecallRoute.nowPlaying.rawValue)
        }
        if disabled.contains(HubRecallRoute.gpsDelivery.rawValue) { return false }
        if row.healthIncluded && disabled.contains(HubRecallRoute.healthSnapshot.rawValue) { return false }
        if row.nowPlayingIncluded && disabled.contains(HubRecallRoute.nowPlaying.rawValue) { return false }
        return true
    }

    private static func disabledLegacyRoutes() async -> Set<String> {
        await MainActor.run {
            Set([HubRecallRoute.gpsDelivery, .healthSnapshot, .nowPlaying].compactMap {
                HubTelemetryAdmission.legacyAllowed($0) ? nil : $0.rawValue
            })
        }
    }

    /// Both retry drain and Lane A fallback cross the same frozen-body boundary.
    /// Never authorize an old body using a newly filtered snapshot instead.
    static func scheduleLegacyBatch(_ row: TelemetryBatchLedger.Batch, disabled: Set<String>,
                                    schedule: () async throws -> Void) async rethrows -> Bool {
        guard legacyRoutesAllowed(row, disabled: disabled) else { return false }
        try await schedule()
        return true
    }
}
