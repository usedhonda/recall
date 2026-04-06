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
                    VStack(spacing: 16) {
                        dataStreamsBar
                            .padding(.horizontal, 12)

                        contextStreamsBar
                            .padding(.horizontal, 12)

                        telemetryStatusBanner

                        heroStateSection
                            .padding(.vertical, 8)

                        metersSection
                            .padding(12)
                            .hudBrackets(color: stateColor.opacity(0.5))
                            .hudCardGlow(color: stateColor, isActive: viewModel.isActive)
                            .padding(.horizontal, 12)

                        chunkInfo
                            .padding(.horizontal, 12)

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
                    .padding(.bottom, 16)
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
        .onChange(of: viewModel.isActive) { _, active in
            if active {
                sessionStart = Date()
            } else {
                sessionStart = nil
            }
        }
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

    @ViewBuilder
    private var heroStateSection: some View {
        VStack(spacing: 8) {
            // System prefix
            Text("SYS://STATUS")
                .font(RecallTheme.Fonts.hudData)
                .foregroundStyle(RecallTheme.Colors.textMuted)
                .tracking(2)

            GlitchText(
                text: stateText,
                font: RecallTheme.Fonts.hudHero,
                color: stateColor,
                tracking: 4,
                continuousGlitch: viewModel.isRecording
            )
            .shadow(color: stateColor.opacity(heroGlowOpacity), radius: heroGlowRadius)

            // Accent line
            Rectangle()
                .fill(stateColor)
                .frame(width: 60, height: 2)
                .shadow(color: stateColor.opacity(0.8), radius: 4)

            if viewModel.isActive {
                HStack(spacing: 6) {
                    PulsingDot(color: stateColor, size: 6)
                    Text(subLabel)
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(stateColor)
                        .tracking(1)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.state)
    }

    // MARK: - Meters

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

    // MARK: - Chunk Info

    @ViewBuilder
    private var chunkInfo: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("CHUNKS:")
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                Text("\(viewModel.chunksRecorded)")
                    .font(RecallTheme.Fonts.hudMeter)
                    .foregroundStyle(RecallTheme.Colors.neonCyan)
            }

            if viewModel.isRecording {
                Text(" // ")
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textMuted)
                HStack(spacing: 4) {
                    Text("DUR:")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                    Text(formatDuration(viewModel.currentChunkDuration))
                        .font(RecallTheme.Fonts.hudMeter)
                        .foregroundStyle(RecallTheme.Colors.neonCyan)
                }
            }
        }
    }

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
                    .frame(maxHeight: 200)
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
                icon: motionIcon,
                label: motionLabel,
                isActive: telemetry.motionManager.isEnabled,
                neonColor: RecallTheme.Colors.neonCyan
            ) {
                if telemetry.motionManager.isEnabled {
                    telemetry.motionManager.stop()
                    AppSettings.shared.motionEnabled = false
                } else {
                    telemetry.motionManager.start()
                    AppSettings.shared.motionEnabled = true
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

    private var motionIcon: String {
        switch telemetry.motionManager.currentActivity {
        case "walking": return "figure.walk"
        case "running": return "figure.run"
        case "automotive": return "car.fill"
        case "cycling": return "bicycle"
        case "stationary": return "moon.zzz.fill"
        default: return "figure.walk"
        }
    }

    private var motionLabel: String {
        guard telemetry.motionManager.isEnabled else { return "Motion" }
        let activity = telemetry.motionManager.currentActivity
        return activity == "unknown" ? "Motion" : activity.capitalized
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
        let loc = telemetry.locationManager
        if loc.isEnabled {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let stale = telemetryStaleMinutes(at: context.date)
                if stale >= 5 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        if let lastErr = loc.lastError {
                            Text("LINK DOWN \(Int(stale))m — \(lastErr)")
                                .font(RecallTheme.Fonts.hudMicro)
                        } else {
                            Text("LINK DOWN \(Int(stale))m — no server response")
                                .font(RecallTheme.Fonts.hudMicro)
                        }
                    }
                    .foregroundStyle(stale >= 30 ? RecallTheme.Colors.neonRed : RecallTheme.Colors.neonAmber)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill((stale >= 30 ? RecallTheme.Colors.neonRed : RecallTheme.Colors.neonAmber).opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke((stale >= 30 ? RecallTheme.Colors.neonRed : RecallTheme.Colors.neonAmber).opacity(0.3), lineWidth: 1)
                    )
                    .padding(.horizontal, 12)
                }
            }
        }
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
