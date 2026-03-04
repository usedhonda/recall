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

                ScrollView {
                    VStack(spacing: 16) {
                        dataStreamsBar
                            .padding(.horizontal, 12)

                        NeonDivider()
                            .padding(.horizontal, 24)

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
                    .opacity(0.4)
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
            .neonGlow(color: stateColor, radius: 12)

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
