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

    var minDistance: CLLocationDistance = 20

    /// Current send cadence (parked / walking / fast). GPS speed decides the fast
    /// tier, the motion coprocessor decides walking vs parked — see LocationCadencePolicy.
    private(set) var cadence: LocationCadence = .walking
    /// Seconds between sends at the current cadence, for the HUD.
    var currentSendInterval: TimeInterval { LocationCadencePolicy.sendInterval(for: cadence) }
    private var lastMovementAt = Date()
    private var continuousUpdatesRunning = false

    // Inputs the cadence decision is made from, surfaced for the HUD.
    /// Speed of the last fix that was accurate enough to believe (m/s).
    private(set) var lastTrustedSpeed: Double?
    /// Horizontal accuracy of the last fix that arrived, accepted or not (m).
    private(set) var lastFixAccuracy: Double?
    /// Why the last arriving fix was rejected, if it was.
    private(set) var lastRejectReason: String?
    private(set) var parkedRegionArmed = false
    /// When a fix last arrived at all (accepted or rejected). Continuous updates going
    /// quiet is otherwise invisible: the only symptom is that nothing is ever sent.
    private(set) var lastFixArrivalAt: Date?
    /// When movement was first noticed while parked, so the first send after it can be
    /// logged with the latency the owner actually cares about ("how fast is departure
    /// noticed?"). Cleared once that send goes out.
    private var departureNoticedAt: Date?
    private var departureFixLogged = false
    /// While set, the parked tier keeps full accuracy to check the position really held.
    private var parkedProbeUntil: Date?
    private var lastUpdatesRestartAt: Date?
    private let noFixRestartAfter: TimeInterval = 180
    var secondsSinceLastMovement: TimeInterval { Date().timeIntervalSince(lastMovementAt) }
    var lastAcceptedFixAge: TimeInterval? {
        lastGoodLocation.map { Date().timeIntervalSince($0.timestamp) }
    }
    var lastSendAge: TimeInterval? {
        lastSentTime.map { Date().timeIntervalSince($0) }
    }
    /// Geofence armed around wherever the phone parked, so leaving is caught even if
    /// the motion chip is slow to call it walking (and coarse parked fixes cannot).
    private static let parkedRegionID = "recall.parked-spot"
    static let parkedRegionRadius: CLLocationDistance = 100

    /// The heartbeat timer ticks faster than the interval it enforces. Ticking once
    /// per interval meant a tick landing a few ms early failed the elapsed check and
    /// the send slipped to the next tick — a 600 s gap instead of 300 s, which is
    /// past the server's 10 min staleness threshold and made leaving home look late.
    private let heartbeatTickInterval: TimeInterval = 60
    private let heartbeatTolerance: TimeInterval = 2

    // MARK: - Send Status

    private(set) var lastSentTime: Date?
    private(set) var lastHttpAcceptedAt: Date?
    private(set) var lastNewAcceptedAt: Date?

    // MARK: - Private Properties

    private let locationManager = CLLocationManager()
    private var lastSentLocation: CLLocation?
    private var lastGoodLocation: CLLocation?
    /// Identity of `lastGoodLocation`. Every POST carrying that fix, and every crossing
    /// event raised while it was the newest accepted one, quote the same value so the
    /// server can join departure -> position -> greeting. It is re-issued only when a
    /// genuinely different fix is accepted: the forced send after a crossing replays the
    /// same `CLLocation`, and a fresh id there would break the join.
    private(set) var lastGoodFixId: String?
    private var lastGoodFixKey: String?
    private var jumpRejectStreak = 0
    private var lastKickAt: Date?
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
        isEnabled = savedEnabled
    }

    // MARK: - Authorization

    func requestAuthorization() {
        let shouldRequestAlways = backgroundEnabled || !AppSettings.shared.locationAnchors.isEmpty
        switch authorizationStatus {
        case .notDetermined:
            if shouldRequestAlways {
                locationManager.requestAlwaysAuthorization()
            } else {
                locationManager.requestWhenInUseAuthorization()
            }
        case .authorizedWhenInUse:
            if shouldRequestAlways {
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

            if backgroundActivitySession == nil {
                backgroundActivitySession = CLBackgroundActivitySession()
                ActivityLogger.shared.log(.location, "Started CLBackgroundActivitySession")
            }
        }

        // Single continuous delivery path: standard updates via the delegate.
        // `CLLocationUpdate.liveUpdates()` used to run alongside and re-delivered
        // the same fixes, so every fix was processed (and sent) twice. Standard
        // updates never auto-pause in BG (pausesLocationUpdatesAutomatically =
        // false), which keeps the app alive for the stationary heartbeat.
        // Keep Best accuracy in the background; only throttle frequency.
        locationManager.distanceFilter = 10
        locationManager.activityType = .other
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.startUpdatingLocation()

        continuousUpdatesRunning = true

        MotionActivityMonitor.shared.onMovementStart = { [weak self] in
            self?.resumeForMovement(reason: "motion")
        }
        MotionActivityMonitor.shared.start()

        refreshRegions()
        startHeartbeatTimer()
        ActivityLogger.shared.log(.location, "Location updates started (bg=\(backgroundEnabled) canBg=\(canUseBackground) auth=\(authorizationStatus.rawValue))")
    }

    func stopUpdates() {
        isUpdating = false
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil

        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil

        MotionActivityMonitor.shared.stop()
        locationManager.stopUpdatingLocation()
        continuousUpdatesRunning = false
        locationManager.stopMonitoringSignificantLocationChanges()
        stopAllRegions()
        ActivityLogger.shared.log(.location, "Location updates stopped")
    }

    func refreshRegions() {
        stopAllRegions()
        startAnchorRegions()
    }

    private func handleLocationUpdate(_ location: CLLocation) async {
        currentLocation = location
        lastFixArrivalAt = Date()

        let isInForeground = UIApplication.shared.applicationState == .active
        // Accuracy and distance filter are owned by the cadence (Best while moving,
        // coarse while parked) — see apply(cadence:).

        guard shouldAcceptLocation(location) else { return }

        logDepartureFixIfPending(location)
        updateCadence(for: location, isInForeground: isInForeground)
        lastGoodLocation = location
        noteGoodFix(location)

        guard shouldSendLocation(location) else { return }

        let quality = qualityFor(location)

        if isInForeground {
            let payload = LocationPayload(from: location, quality: quality, fixId: lastGoodFixId)

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
                logDepartureLatencyIfPending()
                ActivityLogger.shared.log(.location, String(
                    format: "Sent: %.4f, %.4f (%.0fm)%@",
                    location.coordinate.latitude,
                    location.coordinate.longitude,
                    location.horizontalAccuracy,
                    formatLocationMeta(location)
                ))
            } else if case .httpError(let detail) = result {
                totalHttpErrors += 1
                recordNetworkError(detail)
            }
        } else {
            // BG: try direct send first, fallback to queue on failure
            let payload = LocationPayload(from: location, quality: quality, fixId: lastGoodFixId)

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
                logDepartureLatencyIfPending()
                ActivityLogger.shared.log(.location, String(
                    format: "BG direct sent: %.4f, %.4f (%.0fm)%@",
                    location.coordinate.latitude,
                    location.coordinate.longitude,
                    location.horizontalAccuracy,
                    formatLocationMeta(location)
                ))
            } else {
                // Direct send failed — fallback to queue
                if case .httpError(let detail) = result {
                    totalHttpErrors += 1
                    recordNetworkError(detail)
                }
                let sample = LocationSample(from: location, quality: quality, fixId: lastGoodFixId)
                await LocationQueue.shared.enqueue(sample)
                totalQueuedBackgroundSends += 1
                lastSentLocation = location
                lastSentTime = Date()
                resetHeartbeatTimer()

                ActivityLogger.shared.log(.location, String(
                    format: "BG queued (fallback): %.4f, %.4f (%.0fm)%@",
                    location.coordinate.latitude,
                    location.coordinate.longitude,
                    location.horizontalAccuracy,
                    formatLocationMeta(location)
                ))

                await TelemetryUploader.shared.triggerUpload()
            }
        }
    }

    // MARK: - Cadence

    /// Recompute the cadence from this fix. Speed comes from the fix itself when the
    /// OS supplies it, otherwise from displacement since the previous good fix.
    private func updateCadence(for location: CLLocation, isInForeground: Bool) {
        var speed = LocationCadencePolicy.trustedSpeed(
            fixSpeed: location.speed,
            horizontalAccuracy: location.horizontalAccuracy
        )
        if speed == nil,
           let prev = lastGoodLocation,
           location.horizontalAccuracy <= LocationCadencePolicy.speedTrustAccuracy,
           prev.horizontalAccuracy <= LocationCadencePolicy.speedTrustAccuracy {
            let dt = location.timestamp.timeIntervalSince(prev.timestamp)
            if dt >= 1 { speed = location.distance(from: prev) / dt }
        }
        lastTrustedSpeed = speed
        if let speed, speed >= LocationCadencePolicy.movingSpeed { lastMovementAt = Date() }

        let next = nextCadence(speed: speed)
        apply(cadence: next, isInForeground: isInForeground, speed: speed)
    }

    /// Parking is only allowed once one fix has passed the accuracy filter. Indoors a
    /// single coarse request comes back at ~1.6 km, which the filter rejects, so parking
    /// before that left the server with no position at all; continuous Best updates need
    /// a little time to converge.
    private func nextCadence(speed: Double?) -> LocationCadence {
        guard lastGoodLocation != nil else { return .walking }
        return LocationCadencePolicy.tier(
            speed: speed,
            motionSaysMoving: MotionActivityMonitor.shared.isMoving,
            secondsSinceLastMovement: Date().timeIntervalSince(lastMovementAt)
        )
    }

    private func apply(cadence next: LocationCadence, isInForeground: Bool, speed: Double?) {
        if next != cadence {
            let speedText = speed.map { String(format: " %.1fm/s", $0) } ?? ""
            ActivityLogger.shared.log(.location, "Cadence: \(cadence.rawValue) -> \(next.rawValue)\(speedText)")
            cadence = next
            resetHeartbeatTimer()
        }

        switch cadence {
        case .parked:
            // Nothing is moving: drop to coarse, sparse positioning (Wi-Fi / cell
            // instead of a hot GPS chip). Updates must keep running — stopping them
            // ends the location background session, and with audio off iOS suspends
            // the app, which silences the heartbeat and every other stream with it.
            resumeContinuousUpdates()
            // Coarse positioning only pays off once there is an accepted fix to keep
            // re-sending: indoors it returns ~1.8 km readings, which the accuracy filter
            // rejects. Until one good fix exists, stay on Best.
            let probing = (parkedProbeUntil.map { $0 > Date() } ?? false)
            locationManager.desiredAccuracy = (lastGoodLocation == nil || probing)
                ? kCLLocationAccuracyBest
                : kCLLocationAccuracyHundredMeters
            locationManager.distanceFilter = 100
            armParkedRegion()
            MotionActivityMonitor.shared.startShakeWatch()
        case .walking:
            MotionActivityMonitor.shared.stopShakeWatch()
            disarmParkedRegion()
            resumeContinuousUpdates()
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            // No distance filter: a stationary phone delivers almost nothing with one,
            // so GPS never converges and no fix ever passes the accuracy filter. That
            // used to be masked by liveUpdates, which delivered regardless. Sends are
            // rate-limited by the cadence, not by throwing fixes away here.
            locationManager.distanceFilter = kCLDistanceFilterNone
        case .fast:
            MotionActivityMonitor.shared.stopShakeWatch()
            disarmParkedRegion()
            resumeContinuousUpdates()
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone
        }
    }

    /// Re-decide the cadence without a new fix (heartbeat tick).
    private func reevaluateCadence() {
        guard isEnabled, hasAuthorization else { return }
        let next = nextCadence(speed: nil)
        apply(
            cadence: next,
            isInForeground: UIApplication.shared.applicationState == .active,
            speed: nil
        )
    }

    /// Circle around the parked spot. Exiting it wakes the app and resumes GPS, so
    /// leaving is caught even when the motion chip has not called it walking yet and
    /// the coarse parked fixes are too sparse to notice.
    private func armParkedRegion() {
        guard authorizationStatus == .authorizedAlways,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self),
              let center = (lastGoodLocation ?? currentLocation)?.coordinate else { return }
        if locationManager.monitoredRegions.contains(where: { $0.identifier == Self.parkedRegionID }) { return }
        let region = CLCircularRegion(
            center: center,
            radius: Self.parkedRegionRadius,
            identifier: Self.parkedRegionID
        )
        region.notifyOnEntry = false
        region.notifyOnExit = true
        locationManager.startMonitoring(for: region)
        parkedRegionArmed = true
        ActivityLogger.shared.log(.location, "Parked geofence armed (\(Int(Self.parkedRegionRadius))m)")
    }

    private func disarmParkedRegion() {
        for region in locationManager.monitoredRegions where region.identifier == Self.parkedRegionID {
            locationManager.stopMonitoring(for: region)
            parkedRegionArmed = false
            ActivityLogger.shared.log(.location, "Parked geofence cleared")
        }
    }

    /// Continuous updates can go silent (a stale internal flag, or iOS simply stopping
    /// delivery) and nothing else notices — the lane just stops sending. Restart them
    /// when no fix at all has arrived for a few minutes.
    private func restartUpdatesIfStarved() {
        guard isEnabled, hasAuthorization, continuousUpdatesRunning else { return }
        let lastArrival = lastFixArrivalAt ?? .distantPast
        guard Date().timeIntervalSince(lastArrival) >= noFixRestartAfter else { return }
        if let last = lastUpdatesRestartAt, Date().timeIntervalSince(last) < noFixRestartAfter { return }
        lastUpdatesRestartAt = Date()
        let age = Int(Date().timeIntervalSince(lastArrival))
        ActivityLogger.shared.log(.location, "No fixes for \(age)s — restarting location updates")
        locationManager.stopUpdatingLocation()
        locationManager.startUpdatingLocation()
    }

    /// First fix that passed the filter after movement was noticed — separates GPS
    /// acquisition time from network time in the departure latency.
    private func logDepartureFixIfPending(_ location: CLLocation) {
        guard let noticed = departureNoticedAt, !departureFixLogged else { return }
        departureFixLogged = true
        let seconds = Date().timeIntervalSince(noticed)
        let age = Date().timeIntervalSince(location.timestamp)
        ActivityLogger.shared.log(.location, String(
            format: "Departure: first accepted fix %.1fs after movement (acc %.0fm age %.0fs)",
            seconds, location.horizontalAccuracy, age
        ))
    }

    /// First position sent after movement was noticed: the departure latency.
    private func logDepartureLatencyIfPending() {
        guard let noticed = departureNoticedAt else { return }
        departureNoticedAt = nil
        let seconds = Date().timeIntervalSince(noticed)
        ActivityLogger.shared.log(
            .location,
            String(format: "Departure: first position sent %.1fs after movement", seconds)
        )
    }

    private func resumeContinuousUpdates() {
        guard !continuousUpdatesRunning else { return }
        locationManager.startUpdatingLocation()
        continuousUpdatesRunning = true
        ActivityLogger.shared.log(.location, "Location updates on (\(cadence.rawValue))")
    }

    /// Movement seen while parked (motion coprocessor, or a heartbeat fix that moved):
    /// resume GPS and send immediately instead of waiting for the next heartbeat.
    private func resumeForMovement(reason: String) {
        guard isEnabled, hasAuthorization, cadence == .parked else { return }
        ActivityLogger.shared.log(.location, "Movement (\(reason)) — resuming GPS")
        departureNoticedAt = Date()
        departureFixLogged = false
        disarmParkedRegion()
        cadence = .walking
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = UIApplication.shared.applicationState == .active ? kCLDistanceFilterNone : 10
        lastMovementAt = Date()
        resumeContinuousUpdates()
        forceNextSend()
        // No requestLocation here: with continuous updates running Apple documents it as
        // a no-op. Raising desiredAccuracy above is what actually speeds the next fix.
        resetHeartbeatTimer()
    }

    // MARK: - Location Quality Filtering

    private func shouldAcceptLocation(_ location: CLLocation) -> Bool {
        lastFixAccuracy = location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        lastRejectReason = nil
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
            // JumpGate owns the speed/jump decision: a stale prev (e.g. a
            // departure-airport fix after an intl flight, dt >= 300s) bypasses
            // the guard, an isolated glitch is rejected, but a sustained streak
            // of rejections is accepted as real motion (anti-lockup).
            let result = JumpGate.evaluate(
                candidate: (location.coordinate, location.timestamp),
                anchor: (prev.coordinate, prev.timestamp),
                streak: jumpRejectStreak
            )
            jumpRejectStreak = result.streak
            switch result.decision {
            case .accept:
                break
            case .reject:
                markFiltered("jump \(Int(result.impliedSpeed * 3.6))km/h")
                // Streak building: the anchor may be a stale coarse reading
                // holding motion back — kick a fresh high-accuracy fix.
                if result.streak == 2 {
                    kickFreshFix(reason: "jump streak building")
                }
                return false
            case .streakAccept:
                ActivityLogger.shared.log(.location, "jump streak accepted as real motion (streak=\(JumpGate.streakLimit))")
                forceNextSend()
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

    /// Request one fresh high-accuracy fix (e.g. while a jump-reject streak is
    /// building, or when connectivity is restored). The delegate's
    /// `didUpdateLocations` already feeds `handleLocationUpdate`, so this only
    /// nudges the OS. No-op when the stream is off or unauthorized; rate-limited
    /// to at most once per 60 s.
    func kickFreshFix(reason: String) {
        guard isEnabled, hasAuthorization else { return }
        let now = Date()
        if let last = lastKickAt, now.timeIntervalSince(last) < 60 { return }
        lastKickAt = now

        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.requestLocation()
        ActivityLogger.shared.log(.location, "[LOC] fresh-fix kick (\(reason))")
    }

    /// Issues an id for a newly accepted fix, keeping the current one when the same fix
    /// comes round again.
    private func noteGoodFix(_ location: CLLocation) {
        let key = String(
            format: "%.3f|%.6f|%.6f",
            location.timestamp.timeIntervalSince1970,
            location.coordinate.latitude,
            location.coordinate.longitude
        )
        guard key != lastGoodFixKey else { return }
        lastGoodFixKey = key
        lastGoodFixId = UUID().uuidString
    }

    func sendCurrentLocationNow() async {
        forceNextSend()
        guard let location = currentLocation ?? lastGoodLocation else { return }
        await handleLocationUpdate(location)
    }

    private func startAnchorRegions() {
        guard isEnabled else { return }
        let anchors = AppSettings.shared.locationAnchors
        guard !anchors.isEmpty else { return }

        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            ActivityLogger.shared.log(.location, "Region monitoring unavailable")
            return
        }

        guard authorizationStatus == .authorizedAlways else {
            ActivityLogger.shared.log(.location, "Region monitoring needs Always authorization (auth=\(authorizationStatus.rawValue))")
            requestAuthorization()
            return
        }

        for anchor in anchors.prefix(20) {
            let center = CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude)
            let maxRadius = locationManager.maximumRegionMonitoringDistance
            let radius = maxRadius > 0 ? min(max(anchor.radius, 1), maxRadius) : max(anchor.radius, 1)
            let region = CLCircularRegion(center: center, radius: radius, identifier: anchor.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            locationManager.startMonitoring(for: region)
            ActivityLogger.shared.log(.location, "Region monitor started: \(anchor.name) r=\(Int(radius))m")
        }
    }

    private func stopAllRegions() {
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }
    }

    private func anchorName(for region: CLRegion) -> String {
        AppSettings.shared.locationAnchors.first { $0.id.uuidString == region.identifier }?.name ?? region.identifier
    }

    private func shouldSendLocation(_ location: CLLocation) -> Bool {
        guard let lastSent = lastSentLocation, let lastTime = lastSentTime else {
            return true
        }

        let timeSinceLastSend = Date().timeIntervalSince(lastTime)
        let distance = location.distance(from: lastSent)

        return timeSinceLastSend >= currentSendInterval || distance >= minDistance
    }

    /// Formats Phase 1 (Track 2) sample metadata for ActivityLog visibility.
    /// Empty string when nothing meaningful is present so the existing log line
    /// stays compact when the OS doesn't supply enriched fields.
    private func formatLocationMeta(_ location: CLLocation) -> String {
        var parts: [String] = []
        if let level = location.floor?.level { parts.append("f\(level)") }
        if location.verticalAccuracy >= 0 {
            parts.append(String(format: "vA%.0f", location.verticalAccuracy))
        }
        if location.speedAccuracy >= 0 {
            parts.append(String(format: "spdA%.1f", location.speedAccuracy))
        }
        if location.course >= 0 {
            parts.append(String(format: "c%.0f", location.course))
        }
        if let info = location.sourceInformation {
            if info.isProducedByAccessory { parts.append("acc") }
            if info.isSimulatedBySoftware { parts.append("sim") }
        }
        return parts.isEmpty ? "" : " " + parts.joined(separator: " ")
    }

    // MARK: - Heartbeat Timer

    private func startHeartbeatTimer() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(
            withTimeInterval: heartbeatTickInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // A parked phone stops producing fixes (10 m distance filter), so the
                // cadence has to be re-evaluated here too — otherwise it can never
                // reach the parked tier that turns continuous GPS off.
                self?.restartUpdatesIfStarved()
                self?.reevaluateCadence()
                self?.sendHeartbeat()
                BatteryLogger.note()
            }
        }
    }

    private func resetHeartbeatTimer() {
        guard heartbeatTimer != nil else { return }
        startHeartbeatTimer()
    }

    private func sendHeartbeat() {
        // Only ever re-send a fix that passed the accuracy filter. `currentLocation` is
        // assigned before filtering, so falling back to it published rejected fixes:
        // a 1844 m reading went out at 00:40 JST on 2026-09-13, right after a relaunch
        // had left `lastGoodLocation` empty.
        guard let location = lastGoodLocation else {
            // Nothing accepted yet (fresh launch while parked): ask for one good fix.
            kickFreshFix(reason: "heartbeat without an accepted fix")
            return
        }

        let elapsed = lastSentTime.map { Date().timeIntervalSince($0) } ?? .infinity
        guard elapsed >= currentSendInterval - heartbeatTolerance else { return }

        if cadence == .parked {
            // Trains and smooth cars can read as "stationary" to the motion chip, so every
            // heartbeat spends 30 s at full accuracy to see whether the position moved.
            // (requestLocation would be a no-op while continuous updates run.)
            parkedProbeUntil = Date().addingTimeInterval(30)
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
        }

        let quality = qualityFor(location)
        let isInForeground = UIApplication.shared.applicationState == .active

        if isInForeground {
            let payload = LocationPayload(from: location, quality: quality, fixId: lastGoodFixId)
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
            let payload = LocationPayload(from: location, quality: quality, fixId: lastGoodFixId)
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
                        format: "BG heartbeat direct sent: %.4f, %.4f (%.0fm)%@",
                        location.coordinate.latitude,
                        location.coordinate.longitude,
                        location.horizontalAccuracy,
                        self.formatLocationMeta(location)
                    ))
                } else {
                    if case .httpError(let detail) = result {
                        self.totalHttpErrors += 1
                        self.recordNetworkError(detail)
                    }
                    let sample = LocationSample(from: location, quality: quality, fixId: lastGoodFixId)
                    await LocationQueue.shared.enqueue(sample)
                    self.totalQueuedBackgroundSends += 1
                    self.lastSentLocation = location
                    self.lastSentTime = Date()
                    ActivityLogger.shared.log(.location, String(
                        format: "BG heartbeat queued (fallback): %.4f, %.4f (%.0fm)%@",
                        location.coordinate.latitude,
                        location.coordinate.longitude,
                        location.horizontalAccuracy,
                        self.formatLocationMeta(location)
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

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in
            let name = anchorName(for: region)
            ActivityLogger.shared.log(.location, "Region enter: \(name)")
            GeofenceEventReporter.report(
                anchor: name,
                transition: "enter",
                at: Date(),
                accuracy: lastGoodLocation?.horizontalAccuracy,
                fixId: lastGoodFixId
            )
            forceNextSend()
            await sendCurrentLocationNow()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            if region.identifier == Self.parkedRegionID {
                resumeForMovement(reason: "left parked area")
                return
            }
            let name = anchorName(for: region)
            ActivityLogger.shared.log(.location, "Region exit: \(name)")
            GeofenceEventReporter.report(
                anchor: name,
                transition: "exit",
                at: Date(),
                accuracy: lastGoodLocation?.horizontalAccuracy,
                fixId: lastGoodFixId
            )
            forceNextSend()
            await sendCurrentLocationNow()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Task { @MainActor in
            let name = region.map { anchorName(for: $0) } ?? "unknown"
            ActivityLogger.shared.log(.error, "Region monitoring failed: \(name) \(error.localizedDescription)")
            recordNetworkError("Region monitoring failed: \(name) \(error.localizedDescription)")
        }
    }
}

private extension LocationManager {
    func markFiltered(_ reason: String) {
        lastRejectReason = reason
        totalFilteredSamples += 1
        lastAttemptAt = Date()
        lastSendResult = .filtered(reason)
        ActivityLogger.shared.log(.location, "Filtered: \(reason)")
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
