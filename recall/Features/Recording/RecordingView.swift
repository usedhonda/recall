import AVFoundation
import SwiftUI
import SwiftData

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(RecordingViewModel.self) private var viewModel
    private var telemetry = TelemetryService.shared

    private var modelContainer: ModelContainer? {
        modelContext.container
    }

    @State private var showLog = true
    @State private var sessionStart: Date?

    var body: some View {
        VStack(spacing: 0) {
                headerBar

                NeonDivider(color: RecallTheme.Colors.neonCyan)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(spacing: 12) {
                        dataStreamsBar
                            .padding(.horizontal, 12)

                        contextStreamsBar
                            .padding(.horizontal, 12)

                        // Stream detail cards, in the same order as the tiles above and
                        // in the same container: one framed card per stream, no stream
                        // dressed differently from the next.
                        streamCard(accent: stateColor) { recordingCard }
                        streamCard(accent: RecallTheme.Colors.neonCyan) { locationCard }

                        telemetryStatusBanner
                        uploadHealthBanner

                        if let error = viewModel.errorMessage {
                            HStack(spacing: 4) {
                                Text("[ERR]")
                                    .font(RecallTheme.Fonts.hudMicro)
                                    .foregroundStyle(RecallTheme.Colors.neonRed)
                                Text(error)
                                    .font(RecallTheme.Fonts.hudCaption)
                                    .foregroundStyle(RecallTheme.Colors.neonRed)
                            }
                            .padding(.horizontal, 16)
                        }

                        NeonDivider()
                            .padding(.horizontal, 24)

                        activityLogSection
                        }
                    .padding(.bottom, 96)
                }
            }
        .background {
            ZStack {
                Color.black
                Image("cyberpunk_bg")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(0.85)
                VignetteOverlay()
                ScanlineOverlay()
            }
            .ignoresSafeArea()
        }
        .onAppear { MotionActivityMonitor.shared.startLiveSensors() }
        .onDisappear { MotionActivityMonitor.shared.stopLiveSensors() }
        .onChange(of: viewModel.isActive) { _, active in
            if active {
                sessionStart = Date()
            } else {
                sessionStart = nil
            }
        }
    }

    /// Shared container for stream detail cards.
    @ViewBuilder
    private func streamCard<Content: View>(
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(accent.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 12)
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBar: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("R E C A L L")
                .font(RecallTheme.Fonts.hudTitle)
                .foregroundStyle(RecallTheme.Colors.neonCyan)

            Text("v0.1")
                .font(RecallTheme.Fonts.hudData)
                .foregroundStyle(RecallTheme.Colors.textMuted)

            Spacer()

            if let start = sessionStart, viewModel.isActive {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(RecallTheme.Colors.neonGreen)
                            .frame(width: 4, height: 4)
                        Text(formatUptime(elapsed))
                            .font(RecallTheme.Fonts.hudMeter)
                            .foregroundStyle(RecallTheme.Colors.neonCyan)
                    }
                }
            } else {
                Text("STANDBY")
                    .font(RecallTheme.Fonts.hudData)
                    .foregroundStyle(RecallTheme.Colors.textMuted)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Hero State

    // MARK: - Meters

    /// Audio stream card. Same three-part shape as the location card: header line,
    /// body, caption footer.
    @ViewBuilder
    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(
                label: "AUDIO",
                state: stateText,
                stateColor: stateColor,
                detail: viewModel.isActive ? subLabel : nil,
                badge: "CHUNKS \(viewModel.chunksRecorded)",
                badgeColor: RecallTheme.Colors.textSecondary,
                glitch: viewModel.isRecording
            )
            metersSection
            Text(audioFooter)
                .font(RecallTheme.Fonts.hudMicro)
                .foregroundStyle(RecallTheme.Colors.textLabel)
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.state)
    }

    private var audioFooter: String {
        var parts = ["mic \(viewModel.currentMicMode == .bluetoothHFP ? "bluetooth" : "iphone")", "30s max chunk"]
        if viewModel.isRecording {
            parts.insert("current \(formatDuration(viewModel.currentChunkDuration))", at: 0)
        }
        return parts.joined(separator: "  //  ")
    }

    /// One header shape for every stream card: label, state, detail, right-side badge.
    @ViewBuilder
    private func cardHeader(
        label: String,
        state: String,
        stateColor: Color,
        detail: String?,
        badge: String?,
        badgeColor: Color,
        glitch: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(RecallTheme.Fonts.hudCaption)
                .foregroundStyle(RecallTheme.Colors.textLabel)
                .frame(width: 66, alignment: .leading)

            if glitch {
                GlitchText(
                    text: state,
                    font: RecallTheme.Fonts.hudTitle,
                    color: stateColor,
                    tracking: 2,
                    continuousGlitch: true
                )
            } else {
                Text(state)
                    .font(RecallTheme.Fonts.hudTitle)
                    .foregroundStyle(stateColor)
                    .tracking(2)
            }

            if let detail {
                HStack(spacing: 4) {
                    PulsingDot(color: stateColor, size: 5)
                    Text(detail)
                        .font(RecallTheme.Fonts.hudMicro)
                        .foregroundStyle(stateColor)
                }
            }

            Spacer()

            if let badge {
                Text(badge)
                    .font(RecallTheme.Fonts.hudMicro)
                    .foregroundStyle(badgeColor)
            }
        }
    }

    @ViewBuilder
    private var metersSection: some View {
        VStack(spacing: 12) {
            HUDMeterBar(
                label: "SYS.RMS",
                value: viewModel.currentRMS,
                threshold: AppSettings.shared.rmsThreshold,
                barColor: RecallTheme.Colors.neonCyan
            )
            HUDMeterBar(
                label: "SYS.VAD",
                value: viewModel.vadProbability,
                threshold: AppSettings.shared.vadThreshold,
                barColor: RecallTheme.Colors.neonGreen
            )
        }
    }

    /// The location stream's card: same shape as the audio card below it, so the two
    /// streams read as siblings instead of one card and one loose debug line.
    @ViewBuilder
    private var locationCard: some View {
        let location = telemetry.locationManager
        let cadence = location.cadence
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(
                label: "LOCATION",
                state: gpsModeLabel(cadence),
                stateColor: gpsModeColor(cadence),
                detail: nil,
                badge: location.parkedRegionArmed ? "FENCE 100m" : nil,
                badgeColor: RecallTheme.Colors.neonGreen
            )

            Text(cadenceExplanation(cadence))
                .font(RecallTheme.Fonts.hudCaption)
                .foregroundStyle(RecallTheme.Colors.textLabel)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let motion = MotionActivityMonitor.shared
                VStack(alignment: .leading, spacing: 6) {
                    if cadence == .parked {
                        // What is being watched for, and how close each one is to firing.
                        triggerRow(
                            "SHAKE",
                            String(format: "%.2f", motion.parkedShakePeak),
                            String(format: "%.2f g", MotionActivityMonitor.shakeThreshold),
                            motion.parkedShakePeak >= MotionActivityMonitor.shakeThreshold
                        )
                        triggerRow("STEPS", "\(motion.stepsSinceStart)", "any step", motion.stepsSinceStart > 0)
                        triggerRow(
                            "ACTIVITY",
                            motion.isAvailable ? motion.latestActivity : "n/a",
                            "walking",
                            motion.isMoving
                        )
                        triggerRow(
                            "GEOFENCE",
                            location.parkedRegionArmed ? "armed" : "off",
                            String(format: "%.0f m", LocationManager.parkedRegionRadius),
                            false
                        )
                    } else {
                        triggerRow(
                            "SPEED",
                            location.lastTrustedSpeed.map { String(format: "%.1f", $0) } ?? "--",
                            String(format: "%.0f m/s -> FAST", LocationCadencePolicy.fastSpeed),
                            (location.lastTrustedSpeed ?? 0) >= LocationCadencePolicy.fastSpeed
                        )
                        triggerRow(
                            "STILL FOR",
                            formatAge(location.secondsSinceLastMovement),
                            String(format: "%.0fs -> PARKED", LocationCadencePolicy.parkedGrace),
                            location.secondsSinceLastMovement >= LocationCadencePolicy.parkedGrace
                        )
                        triggerRow("STEPS", "\(motion.stepsSinceStart)", "walking", motion.isMoving)
                    }

                    Divider().overlay(RecallTheme.Colors.textMuted.opacity(0.4))

                    HStack(spacing: 0) {
                        diagField("GPS ACC", location.lastFixAccuracy.map { String(format: "%.0f m", $0) } ?? "no fix")
                        diagField("LAST FIX", location.lastAcceptedFixAge.map(formatAge) ?? "--")
                        diagField("LAST SEND", location.lastSendAge.map(formatAge) ?? "--")
                    }
                }
            }

            if let reason = location.lastRejectReason {
                Text("rejected  //  \(reason)")
                    .font(RecallTheme.Fonts.hudMicro)
                    .foregroundStyle(RecallTheme.Colors.neonAmber)
            }
        }
    }

    /// One watched signal: what it reads now, what would trip it, and whether it has.
    @ViewBuilder
    private func triggerRow(_ label: String, _ value: String, _ threshold: String, _ tripped: Bool) -> some View {
        HStack(spacing: 8) {
            Text(tripped ? "[x]" : "[ ]")
                .font(RecallTheme.Fonts.hudMicro)
                .foregroundStyle(tripped ? RecallTheme.Colors.neonGreen : RecallTheme.Colors.textLabel)
            Text(label)
                .font(RecallTheme.Fonts.hudMicro)
                .foregroundStyle(RecallTheme.Colors.textLabel)
                .frame(width: 74, alignment: .leading)
            Text(value)
                .font(RecallTheme.Fonts.hudCaption)
                .foregroundStyle(RecallTheme.Colors.textPrimary)
            Spacer()
            Text(threshold)
                .font(RecallTheme.Fonts.hudMicro)
                .foregroundStyle(RecallTheme.Colors.textLabel)
        }
    }

    /// Plain-language summary of what the current tier does.
    private func cadenceExplanation(_ cadence: LocationCadence) -> String {
        switch cadence {
        case .parked:
            return "GPS coarse, sends every 5 min. Watching for:"
        case .walking:
            return "GPS full, sends on 20 m of movement. Watching for:"
        case .fast:
            return "GPS full, sends every 30 s. Watching for:"
        }
    }

    @ViewBuilder
    private func diagField(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(RecallTheme.Fonts.hudMicro)
                .foregroundStyle(RecallTheme.Colors.textLabel)
            Text(value)
                .font(RecallTheme.Fonts.hudCaption)
                .foregroundStyle(RecallTheme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formatAge(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
    }

    private func gpsModeLabel(_ cadence: LocationCadence) -> String {
        switch cadence {
        case .parked: return "PARKED"
        case .walking: return "WALKING"
        case .fast: return "FAST"
        }
    }

    private func gpsRateLabel(_ cadence: LocationCadence) -> String {
        switch cadence {
        case .parked: return "300s"
        case .walking: return "20m / 300s"
        case .fast: return "30s"
        }
    }

    private func gpsModeColor(_ cadence: LocationCadence) -> Color {
        switch cadence {
        case .parked: return RecallTheme.Colors.textSecondary
        case .walking: return RecallTheme.Colors.neonCyan
        case .fast: return RecallTheme.Colors.neonAmber
        }
    }

    // MARK: - Chunk Info

    // MARK: - Activity Log (Terminal Style)

    @ViewBuilder
    private var activityLogSection: some View {
        VStack(spacing: 4) {
            HStack {
                Text(">_ ACTIVITY LOG")
                    .font(RecallTheme.Fonts.hudTitle)
                    .foregroundStyle(RecallTheme.Colors.neonGreen)
                    .tracking(1)
                Spacer()
                Button {
                    showLog.toggle()
                } label: {
                    Image(systemName: showLog ? "chevron.down" : "chevron.right")
                        .font(RecallTheme.Fonts.hudMicro)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                }
                Button {
                    ActivityLogger.shared.clear()
                } label: {
                    Image(systemName: "xmark")
                        .font(RecallTheme.Fonts.hudMicro)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                }
            }
            .padding(.horizontal, 12)

            if showLog {
                ActivityLogView(entries: ActivityLogger.shared.entries)
                    .frame(minHeight: 220, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(RecallTheme.Colors.neonGreen.opacity(0.2), lineWidth: 1)
                    )
                    .hudBrackets(color: RecallTheme.Colors.neonGreen.opacity(0.4))
                    .padding(.horizontal, 8)
            }
        }
    }

    // MARK: - Data Streams Bar

    @ViewBuilder
    private var dataStreamsBar: some View {
        HStack(spacing: 8) {
            CyberpunkStreamToggle(
                icon: "mic.fill",
                label: "Audio",
                isActive: viewModel.isActive,
                neonColor: RecallTheme.Colors.neonCyan
            ) {
                if viewModel.isActive {
                    viewModel.stop()
                } else {
                    Task {
                        if let container = modelContainer {
                            await viewModel.start(modelContainer: container)
                        }
                    }
                }
            }

            CyberpunkStreamToggle(
                icon: "location.fill",
                label: "Location",
                isActive: telemetry.locationManager.isUpdating,
                neonColor: RecallTheme.Colors.neonCyan
            ) {
                if telemetry.locationManager.isEnabled {
                    telemetry.locationManager.isEnabled = false
                } else {
                    if !telemetry.locationManager.hasAuthorization {
                        telemetry.locationManager.requestAuthorization()
                    }
                    telemetry.locationManager.isEnabled = true
                }
            }

            CyberpunkStreamToggle(
                icon: "heart.fill",
                label: "Health",
                isActive: telemetry.healthManager.isEnabled,
                neonColor: RecallTheme.Colors.neonMagenta
            ) {
                if telemetry.healthManager.isEnabled {
                    telemetry.healthManager.isEnabled = false
                } else {
                    Task {
                        let authorized = await telemetry.healthManager.requestAuthorization()
                        if authorized {
                            telemetry.healthManager.isEnabled = true
                            telemetry.healthManager.startTimer()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Context Streams Bar

    @ViewBuilder
    private var contextStreamsBar: some View {
        HStack(spacing: 8) {
            CyberpunkStreamToggle(
                icon: "sunglasses.fill",
                label: glassesLabel,
                isActive: telemetry.glassesHandoffReceiver.isEnabled,
                neonColor: RecallTheme.Colors.neonAmber,
                iconScale: .small
            ) {
                if telemetry.glassesHandoffReceiver.isEnabled {
                    // Distinguishes user-driven stops from any other path when an
                    // isolated "[handoff] receiver stopped" appears in the logs
                    ActivityLogger.shared.log(.telemetry, "[handoff] glasses toggle tapped by user: stop")
                    telemetry.glassesHandoffReceiver.stop()
                    AppSettings.shared.glassesAutoImportEnabled = false
                } else {
                    ActivityLogger.shared.log(.telemetry, "[handoff] glasses toggle tapped by user: start")
                    if let container = modelContainer {
                        telemetry.glassesHandoffReceiver.setModelContainer(container)
                    }
                    telemetry.glassesHandoffReceiver.start()
                    AppSettings.shared.glassesAutoImportEnabled = true
                }
            }

            CyberpunkStreamToggle(
                icon: "music.note",
                label: "Media",
                isActive: telemetry.nowPlayingManager.isEnabled,
                neonColor: RecallTheme.Colors.neonCyan
            ) {
                if telemetry.nowPlayingManager.isEnabled {
                    telemetry.nowPlayingManager.stop()
                    AppSettings.shared.nowPlayingEnabled = false
                } else {
                    telemetry.nowPlayingManager.start()
                    AppSettings.shared.nowPlayingEnabled = true
                }
            }

            micSelectorSlot
        }
    }

    private var glassesLabel: String {
        guard telemetry.glassesHandoffReceiver.isEnabled else { return "Glasses" }
        let count = telemetry.glassesHandoffReceiver.totalImported
        return count > 0 ? "Glasses (\(count))" : "Glasses"
    }

    // MARK: - Mic Selector

    @ViewBuilder
    private var micSelectorSlot: some View {
        let isBT = viewModel.currentMicMode == .bluetoothHFP

        Button {
            Task {
                await viewModel.switchMicMode(isBT ? .builtIn : .bluetoothHFP)
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isBT ? "headphones" : "mic.fill")
                    .font(.title3)
                Text(isBT ? "BT" : "iPhone")
                    .font(RecallTheme.Fonts.hudMicro)
                    .lineLimit(1)
                Text(isBT ? "MONO" : "STEREO")
                    .font(RecallTheme.Fonts.hudMicro)
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isBT ? RecallTheme.Colors.neonMagenta.opacity(0.12) : RecallTheme.Colors.neonCyan.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(
                        isBT ? RecallTheme.Colors.neonMagenta.opacity(0.4) : RecallTheme.Colors.neonCyan.opacity(0.4),
                        lineWidth: 1
                    )
            )
            .foregroundStyle(isBT ? RecallTheme.Colors.neonMagenta : RecallTheme.Colors.neonCyan)
        }
        .buttonStyle(.plain)
    }

    private func micIcon(for portType: AVAudioSession.Port?) -> String {
        switch portType {
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE:
            return "headphones"
        case .headsetMic, .headphones:
            return "headphones"
        case .usbAudio:
            return "cable.connector"
        default:
            return "mic.fill"
        }
    }

    private func shortMicName(_ name: String) -> String {
        if name.count <= 8 { return name }
        // Abbreviate long names
        let words = name.split(separator: " ")
        if words.count >= 2 {
            return String(words[0].prefix(6))
        }
        return String(name.prefix(8))
    }

    // MARK: - Telemetry Status Banner

    @ViewBuilder
    private var telemetryStatusBanner: some View {
        // Suppressed during gateway plugin-loader outage (2026-05-03).
        // Restore once /api/telemetry route is back to avoid silently hiding real link issues.
        EmptyView()
    }

    private func telemetryStaleMinutes(at now: Date) -> TimeInterval {
        let loc = telemetry.locationManager
        guard let lastSuccess = loc.lastHttpAcceptedAt else {
            // Never sent successfully — show stale if location has been enabled for > 1 min
            guard loc.isUpdating else { return 0 }
            return 5 // trigger banner immediately
        }
        return now.timeIntervalSince(lastSuccess) / 60
    }

    // MARK: - Upload Health Banner

    @ViewBuilder
    private var uploadHealthBanner: some View {
        let connectivity = ConnectivityMonitor.shared
        let health = ServerHealthMonitor.shared
        let upload = UploadManager.shared

        TimelineView(.periodic(from: .now, by: 15)) { context in
            let now = context.date
            let message = uploadHealthMessage(
                isConnected: connectivity.isConnected,
                isReachable: health.isServerReachable,
                lastUploadSuccess: health.lastUploadSuccessAt,
                pendingCount: upload.pendingCount,
                now: now
            )
            if let (text, severity) = message {
                let color = severity == .critical
                    ? RecallTheme.Colors.neonRed
                    : RecallTheme.Colors.neonAmber
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                    Text(text)
                        .font(RecallTheme.Fonts.hudMicro)
                }
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.1))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
                .padding(.horizontal, 12)
            }
        }
    }

    private enum BannerSeverity { case warning, critical }

    private func uploadHealthMessage(
        isConnected: Bool,
        isReachable: Bool,
        lastUploadSuccess: Date?,
        pendingCount: Int,
        now: Date
    ) -> (String, BannerSeverity)? {
        if !isConnected {
            return ("OFFLINE", .critical)
        }
        // Server-side outage banners (UNREACHABLE / STALLED) are suppressed during the
        // gateway plugin-loader outage (2026-05-03). Restore once /api/telemetry route
        // is back so legitimate server problems become visible again.
        return nil
    }

    // MARK: - Helpers

    private var stateColor: Color {
        switch viewModel.state {
        case .idle: RecallTheme.Colors.textMuted
        case .listening: RecallTheme.Colors.neonCyan
        case .recording: RecallTheme.Colors.neonGreen
        case .paused: RecallTheme.Colors.neonAmber
        }
    }

    private var stateText: String {
        switch viewModel.state {
        case .idle: "IDLE"
        case .listening: "LISTENING"
        case .recording: "RECORDING"
        case .paused: "PAUSED"
        }
    }

    private var heroGlowOpacity: CGFloat {
        switch viewModel.state {
        case .idle: 0
        case .listening: 0.3
        case .recording: 0.6
        case .paused: 0.2
        }
    }

    private var heroGlowRadius: CGFloat {
        switch viewModel.state {
        case .idle: 0
        case .listening: 4
        case .recording: 8
        case .paused: 3
        }
    }

    private var subLabel: String {
        switch viewModel.state {
        case .recording: "VOICE DETECTED"
        case .listening: "MONITORING"
        case .paused: "PAUSED"
        case .idle: ""
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func formatUptime(_ interval: TimeInterval) -> String {
        let h = Int(interval) / 3600
        let m = (Int(interval) % 3600) / 60
        let s = Int(interval) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
