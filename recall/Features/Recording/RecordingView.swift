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
        ZStack {
            RecallTheme.Colors.bg.ignoresSafeArea()
            ScanlineOverlay().ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar

                ScrollView {
                    VStack(spacing: 12) {
                        dataStreamsBar
                            .padding(.horizontal, 12)

                        heroStateSection
                            .padding(.vertical, 16)

                        metersSection
                            .hudCardGlow(color: stateColor, isActive: viewModel.isActive)
                            .padding(.horizontal, 12)

                        chunkInfo
                            .padding(.horizontal, 12)

                        if let error = viewModel.errorMessage {
                            Text(error)
                                .font(RecallTheme.Fonts.hudCaption)
                                .foregroundStyle(RecallTheme.Colors.neonRed)
                                .padding(.horizontal)
                        }

                        activityLogSection
                    }
                    .padding(.bottom, 16)
                }
            }
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
        HStack {
            Text("RECALL")
                .font(RecallTheme.Fonts.hudTitle)
                .foregroundStyle(RecallTheme.Colors.neonCyan)
                .tracking(4)
            Spacer()
            if let start = sessionStart, viewModel.isActive {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    let elapsed = context.date.timeIntervalSince(start)
                    Text(formatUptime(elapsed))
                        .font(RecallTheme.Fonts.hudMeter)
                        .foregroundStyle(RecallTheme.Colors.neonCyan)
                        .neonGlow(color: RecallTheme.Colors.neonCyan, radius: 8)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Hero State

    @ViewBuilder
    private var heroStateSection: some View {
        VStack(spacing: 10) {
            GlitchText(
                text: stateText,
                font: RecallTheme.Fonts.hudHero,
                color: stateColor,
                tracking: 6,
                continuousGlitch: viewModel.isRecording
            )
            .neonGlow(color: stateColor, radius: 16)

            if viewModel.isActive {
                HStack(spacing: 6) {
                    PulsingDot(color: stateColor)
                    Text(subLabel)
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(stateColor)
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
                label: "RMS",
                value: viewModel.currentRMS,
                threshold: AppSettings.shared.rmsThreshold,
                barColor: RecallTheme.Colors.neonCyan
            )
            HUDMeterBar(
                label: "VAD",
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
                Text("  |  ")
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textMuted)
                HStack(spacing: 4) {
                    Text("DURATION:")
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
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(RecallTheme.Colors.neonGreen.opacity(0.3), lineWidth: 1)
                    )
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
