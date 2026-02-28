import Foundation
import CoreLocation
import Observation
import UIKit

/// Manages location updates for telemetry
@MainActor
@Observable
final class LocationManager: NSObject {
    private static let maxErrorHistoryCount = 5
    private static let errorDedupWindow: TimeInterval = 10

    // MARK: - Published State

    private(set) var currentLocation: CLLocation?
    private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    private(set) var isUpdating = false
    private(set) var lastError: String?
    private(set) var lastErrorAt: Date?
    private(set) var lastSendResult: LocationSendResult = .none
    private(set) var errorHistory: [NetworkError] = []
    private(set) var suppressedDuplicateErrors = 0
    private(set) var totalAttemptedSends = 0
    private(set) var totalSuccessfulSends = 0
    private(set) var totalFilteredSamples = 0
    private(set) var totalHttpErrors = 0
    private(set) var totalQueuedBackgroundSends = 0
    private(set) var lastAttemptAt: Date?

    // MARK: - Settings

    var isEnabled: Bool = false {
        didSet {
            AppSettings.shared.locationEnabled = isEnabled
            if isEnabled {
                ActivityLogger.shared.log(.location, "Location enabled (auth=\(hasAuthorization))")
                startUpdates()
            } else {
                stopUpdates()
            }
        }
    }

    var backgroundEnabled: Bool = false {
        didSet {
            AppSettings.shared.locationBackgroundEnabled = backgroundEnabled
            configureBackgroundMode()
        }
    }

    var minSendInterval: TimeInterval = 15 {
        didSet {
            AppSettings.shared.telemetrySendInterval = minSendInterval
        }
    }

    var minDistance: CLLocationDistance = 50

    // MARK: - Send Status

    private(set) var lastSentTime: Date?
    private(set) var lastHttpAcceptedAt: Date?
    private(set) var lastNewAcceptedAt: Date?

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private var lastSentLocation: CLLocation?
    private var lastGoodLocation: CLLocation?
    private var updateTask: Task<Void, Never>?
    private var heartbeatTimer: Timer?
    private var backgroundActivitySession: CLBackgroundActivitySession?

    // MARK: - Initialization

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = kCLDistanceFilterNone
        authorizationStatus = locationManager.authorizationStatus
    }

    /// Restore settings from AppSettings
    func restoreSettings() {
        let settings = AppSettings.shared
        let savedInterval = settings.telemetrySendInterval
        if savedInterval > 0 {
            minSendInterval = savedInterval
        }
        backgroundEnabled = settings.locationBackgroundEnabled

        let savedEnabled = settings.locationEnabled
        if savedEnabled && hasAuthorization {
            isEnabled = true
        }
    }

    // MARK: - Authorization

    func requestAuthorization() {
        switch authorizationStatus {
        case .notDetermined:
            if backgroundEnabled {
                locationManager.requestAlwaysAuthorization()
            } else {
                locationManager.requestWhenInUseAuthorization()
            }
        case .authorizedWhenInUse:
            if backgroundEnabled {
                locationManager.requestAlwaysAuthorization()
            }
        default:
            break
        }
    }

    var hasAuthorization: Bool {
        switch authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        default:
            return false
        }
    }

    var canUseBackground: Bool {
        authorizationStatus == .authorizedAlways
    }

    var isReducedAccuracy: Bool {
        locationManager.accuracyAuthorization == .reducedAccuracy
    }

    // MARK: - Location Updates

    func startUpdates() {
        guard isEnabled, hasAuthorization else {
            if isEnabled && !hasAuthorization {
                requestAuthorization()
            }
            return
        }

        isUpdating = true
        lastError = nil

        if backgroundEnabled && hasAuthorization {
            locationManager.startMonitoringSignificantLocationChanges()
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 10
            locationManager.activityType = .other
            locationManager.startUpdatingLocation()

            if backgroundActivitySession == nil {
                backgroundActivitySession = CLBackgroundActivitySession()
                ActivityLogger.shared.log(.location, "Started CLBackgroundActivitySession")
            }
        }

        startLiveUpdates()
        ActivityLogger.shared.log(.location, "Location updates started (bg=\(backgroundEnabled) canBg=\(canUseBackground) auth=\(authorizationStatus.rawValue))")
    }

    func stopUpdates() {
        isUpdating = false
        updateTask?.cancel()
        updateTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil

        locationManager.stopUpdatingLocation()
        locationManager.stopMonitoringSignificantLocationChanges()
        ActivityLogger.shared.log(.location, "Location updates stopped")
    }

    private func startLiveUpdates() {
        updateTask?.cancel()

        updateTask = Task {
            do {
                let updates = CLLocationUpdate.liveUpdates()
                var updateCount = 0

                for try await update in updates {
                    guard !Task.isCancelled else { break }
                    updateCount += 1

                    if let location = update.location {
                        await handleLocationUpdate(location)
                    }
                }
            } catch {
                lastError = error.localizedDescription
                ActivityLogger.shared.log(.location, "liveUpdates error: \(error.localizedDescription)")
            }
        }

        startHeartbeatTimer()
    }

    private func handleLocationUpdate(_ location: CLLocation) async {
        currentLocation = location

        let isInForeground = UIApplication.shared.applicationState == .active
        if isInForeground {
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone
        } else {
            locationManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            locationManager.distanceFilter = 10
        }

        guard shouldAcceptLocation(location) else { return }

        lastGoodLocation = location

        guard shouldSendLocation(location) else { return }

        let quality = qualityFor(location)

        if isInForeground {
            let payload = LocationPayload(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy,
                altitude: location.altitude,
                speed: location.speed >= 0 ? location.speed : nil,
                timestamp: location.timestamp,
                quality: quality
            )

            totalAttemptedSends += 1
            lastAttemptAt = Date()
            let result = await TelemetryService.shared.sendLocation(payload)
            lastSendResult = result
            if case .sent(_, let received, _, _) = result {
                totalSuccessfulSends += 1
                lastSentLocation = location
                lastSentTime = Date()
                lastHttpAcceptedAt = Date()
                lastError = nil
                lastErrorAt = nil
                if let received, received > 0 {
                    lastNewAcceptedAt = Date()
                }
                resetHeartbeatTimer()
                ActivityLogger.shared.log(.location, String(
                    format: "Sent: %.4f, %.4f (%.0fm)",
                    location.coordinate.latitude,
                    location.coordinate.longitude,
                    location.horizontalAccuracy
                ))
            } else if case .httpError(let detail) = result {
                totalHttpErrors += 1
                recordNetworkError(detail)
            }
        } else {
            // BG: try direct send first, fallback to queue on failure
            let payload = LocationPayload(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy,
                altitude: location.altitude,
                speed: location.speed >= 0 ? location.speed : nil,
                timestamp: location.timestamp,
                quality: quality
            )

            totalAttemptedSends += 1
            lastAttemptAt = Date()
            let result = await TelemetryService.shared.sendLocation(payload)
            lastSendResult = result

            if case .sent(_, let received, _, _) = result {
                // Direct send succeeded — same as FG path
                totalSuccessfulSends += 1
                lastSentLocation = location
                lastSentTime = Date()
                lastHttpAcceptedAt = Date()
                lastError = nil
                lastErrorAt = nil
                if let received, received > 0 {
                    lastNewAcceptedAt = Date()
                }
                resetHeartbeatTimer()
                ActivityLogger.shared.log(.location, String(
                    format: "BG direct sent: %.4f, %.4f (%.0fm)",
                    location.coordinate.latitude,
                    location.coordinate.longitude,
                    location.horizontalAccuracy
                ))
            } else {
                // Direct send failed — fallback to queue
                if case .httpError(let detail) = result {
                    totalHttpErrors += 1
                    recordNetworkError(detail)
                }
                let sample = LocationSample(from: location)
                await LocationQueue.shared.enqueue(sample)
                totalQueuedBackgroundSends += 1
                lastSentLocation = location
                lastSentTime = Date()
                resetHeartbeatTimer()

                ActivityLogger.shared.log(.location, String(
                    format: "BG queued (fallback): %.4f, %.4f (%.0fm)",
                    location.coordinate.latitude,
                    location.coordinate.longitude,
                    location.horizontalAccuracy
                ))

                await TelemetryUploader.shared.triggerUpload()
            }
        }
    }

    // MARK: - Location Quality Filtering

    private func shouldAcceptLocation(_ location: CLLocation) -> Bool {
        guard location.horizontalAccuracy >= 0 else {
            markFiltered("invalid accuracy")
            return false
        }

        let isBackground = UIApplication.shared.applicationState != .active

        let maxAccuracy = isBackground ? 200.0 : 100.0
        guard location.horizontalAccuracy <= maxAccuracy else {
            markFiltered("accuracy \(Int(location.horizontalAccuracy))m")
            return false
        }

        let age = Date().timeIntervalSince(location.timestamp)
        let maxAge = isBackground ? 120.0 : 30.0
        guard age <= maxAge else {
            markFiltered("age \(Int(age))s")
            return false
        }

        if let prev = lastGoodLocation {
            let distance = location.distance(from: prev)
            let dt = location.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0 {
                let speed = distance / dt
                if speed > 55.6 {  // 200km/h
                    markFiltered("jump \(Int(speed * 3.6))km/h")
                    return false
                }
            }
        }

        return true
    }

    private func qualityFor(_ location: CLLocation) -> String {
        if isReducedAccuracy { return "approx" }
        if location.horizontalAccuracy > 100 { return "approx" }
        return "good"
    }

    func forceNextSend() {
        lastSentLocation = nil
        lastSentTime = nil
        lastHttpAcceptedAt = nil
        lastNewAcceptedAt = nil
    }

    func sendCurrentLocationNow() async {
        forceNextSend()
        guard let location = currentLocation ?? lastGoodLocation else { return }
        await handleLocationUpdate(location)
    }

    private func shouldSendLocation(_ location: CLLocation) -> Bool {
        guard let lastSent = lastSentLocation, let lastTime = lastSentTime else {
            return true
        }

        let timeSinceLastSend = Date().timeIntervalSince(lastTime)
        let distance = location.distance(from: lastSent)

        return timeSinceLastSend >= minSendInterval || distance >= minDistance
    }

    // MARK: - Heartbeat Timer

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: minSendInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendHeartbeat()
            }
        }
    }

    private func resetHeartbeatTimer() {
        guard heartbeatTimer != nil else { return }
        startHeartbeatTimer()
    }

    private func sendHeartbeat() {
        guard let location = lastGoodLocation ?? currentLocation else { return }

        let elapsed = lastSentTime.map { Date().timeIntervalSince($0) } ?? .infinity
        guard elapsed >= minSendInterval else { return }

        let quality = qualityFor(location)
        let isInForeground = UIApplication.shared.applicationState == .active

        if isInForeground {
            let payload = LocationPayload(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy,
                altitude: location.altitude,
                speed: location.speed >= 0 ? location.speed : nil,
                timestamp: location.timestamp,
                quality: quality
            )
            Task {
                self.totalAttemptedSends += 1
                self.lastAttemptAt = Date()
                let result = await TelemetryService.shared.sendLocation(payload)
                self.lastSendResult = result
                if case .sent(_, let received, _, _) = result {
                    self.totalSuccessfulSends += 1
                    self.lastSentLocation = location
                    self.lastSentTime = Date()
                    self.lastHttpAcceptedAt = Date()
                    self.lastError = nil
                    self.lastErrorAt = nil
                    if let received, received > 0 {
                        self.lastNewAcceptedAt = Date()
                    }
                } else if case .httpError(let detail) = result {
                    self.totalHttpErrors += 1
                    self.recordNetworkError(detail)
                }
            }
        } else {
            // BG heartbeat: try direct send first, fallback to queue
            let payload = LocationPayload(
                latitude: location.coordinate.latitude,
                longitude: location.coordinate.longitude,
                accuracy: location.horizontalAccuracy,
                altitude: location.altitude,
                speed: location.speed >= 0 ? location.speed : nil,
                timestamp: location.timestamp,
                quality: quality
            )
            Task {
                self.totalAttemptedSends += 1
                self.lastAttemptAt = Date()
                let result = await TelemetryService.shared.sendLocation(payload)
                self.lastSendResult = result

                if case .sent(_, let received, _, _) = result {
                    self.totalSuccessfulSends += 1
                    self.lastSentLocation = location
                    self.lastSentTime = Date()
                    self.lastHttpAcceptedAt = Date()
                    self.lastError = nil
                    self.lastErrorAt = nil
                    if let received, received > 0 {
                        self.lastNewAcceptedAt = Date()
                    }
                    ActivityLogger.shared.log(.location, String(
                        format: "BG heartbeat direct sent: %.4f, %.4f (%.0fm)",
                        location.coordinate.latitude,
                        location.coordinate.longitude,
                        location.horizontalAccuracy
                    ))
                } else {
                    if case .httpError(let detail) = result {
                        self.totalHttpErrors += 1
                        self.recordNetworkError(detail)
                    }
                    let sample = LocationSample(from: location)
                    await LocationQueue.shared.enqueue(sample)
                    self.totalQueuedBackgroundSends += 1
                    self.lastSentLocation = location
                    self.lastSentTime = Date()
                    ActivityLogger.shared.log(.location, String(
                        format: "BG heartbeat queued (fallback): %.4f, %.4f (%.0fm)",
                        location.coordinate.latitude,
                        location.coordinate.longitude,
                        location.horizontalAccuracy
                    ))
                    await TelemetryUploader.shared.triggerUpload()
                }
            }
        }
    }

    private func configureBackgroundMode() {
        if backgroundEnabled && hasAuthorization {
            // Enable background location with WhenInUse or Always auth
            // iOS 17+ supports background location with WhenInUse + CLBackgroundActivitySession
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.pausesLocationUpdatesAutomatically = false
            locationManager.showsBackgroundLocationIndicator = true
            ActivityLogger.shared.log(.location, "Background mode ENABLED (auth=\(authorizationStatus.rawValue))")
        } else {
            locationManager.allowsBackgroundLocationUpdates = false
            if backgroundEnabled {
                ActivityLogger.shared.log(.location, "Background mode not configured (auth=\(authorizationStatus.rawValue))")
            }
        }
    }

    func updateSendInterval(_ interval: Int) {
        minSendInterval = max(TimeInterval(interval), 15)
    }

    func resetRuntimeCounters() {
        totalAttemptedSends = 0
        totalSuccessfulSends = 0
        totalFilteredSamples = 0
        totalHttpErrors = 0
        totalQueuedBackgroundSends = 0
        lastAttemptAt = nil
        suppressedDuplicateErrors = 0
        errorHistory.removeAll()
        lastError = nil
        lastErrorAt = nil
        lastSendResult = .none
    }

    var shouldShowConnectionErrorBanner: Bool {
        guard let lastError, !lastError.isEmpty, let errorAt = lastErrorAt else { return false }
        if let successAt = lastHttpAcceptedAt, successAt >= errorAt {
            return false
        }
        return Date().timeIntervalSince(errorAt) <= 45
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let oldStatus = authorizationStatus
            authorizationStatus = manager.authorizationStatus
            ActivityLogger.shared.log(.location, "Authorization changed: \(oldStatus.rawValue) -> \(authorizationStatus.rawValue) (always=\(canUseBackground))")

            // Reconfigure background mode when authorization changes
            configureBackgroundMode()

            if hasAuthorization && isEnabled {
                startUpdates()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        Task { @MainActor in
            await handleLocationUpdate(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            lastError = error.localizedDescription
            lastErrorAt = Date()
            recordNetworkError(error.localizedDescription)
        }
    }
}

private extension LocationManager {
    func markFiltered(_ reason: String) {
        totalFilteredSamples += 1
        lastAttemptAt = Date()
        lastSendResult = .filtered(reason)
    }

    func recordNetworkError(_ message: String) {
        let now = Date()
        lastError = message
        lastErrorAt = now
        if let first = errorHistory.first,
           first.message == message,
           now.timeIntervalSince(first.timestamp) < Self.errorDedupWindow {
            suppressedDuplicateErrors += 1
            return
        }

        errorHistory.insert(NetworkError(timestamp: now, message: message), at: 0)
        if errorHistory.count > Self.maxErrorHistoryCount {
            errorHistory.removeLast()
        }
    }
}
