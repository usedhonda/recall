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

    var body: some View {
        VStack(spacing: 0) {
            HUDHeaderBar(title: "recall")

            ScrollView {
                VStack(spacing: 12) {
                    dataStreamsBar
                        .padding(.horizontal, 12)

                    stateIndicator
                        .padding(.vertical, 8)

                    metersSection
                        .hudCard()
                        .padding(.horizontal, 12)

                    chunkInfo
                        .padding(.horizontal, 12)

                    controlButton
                        .padding(.vertical, 4)

                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.neonRed)
                            .padding(.horizontal)
                    }

                    // Activity Log
                    VStack(spacing: 4) {
                        HStack {
                            HUDSectionHeader(title: "Activity Log")
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
                                Image(systemName: "trash")
                                    .font(RecallTheme.Fonts.hudMicro)
                                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                            }
                        }
                        .padding(.horizontal, 12)

                        if showLog {
                            ActivityLogView(entries: ActivityLogger.shared.entries)
                                .frame(maxHeight: 200)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(RecallTheme.Colors.bg)
    }

    @ViewBuilder
    private var stateIndicator: some View {
        VStack(spacing: 6) {
            Text(stateText)
                .font(RecallTheme.Fonts.hudLarge)
                .foregroundStyle(stateColor)
                .shadow(color: viewModel.isRecording ? stateColor.opacity(0.6) : .clear, radius: 8)

            if viewModel.isRecording {
                HStack(spacing: 6) {
                    Circle()
                        .fill(RecallTheme.Colors.neonGreen)
                        .frame(width: 6, height: 6)
                    Text("ACTIVE")
                        .font(RecallTheme.Fonts.hudMicro)
                        .foregroundStyle(RecallTheme.Colors.neonGreen)
                }
            }
        }
    }

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

    @ViewBuilder
    private var controlButton: some View {
        Button {
            if viewModel.isActive {
                viewModel.stop()
            } else {
                Task {
                    if let container = modelContainer {
                        await viewModel.start(modelContainer: container)
                    }
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(controlColor.opacity(0.08))
                    .frame(width: 80, height: 80)
                Circle()
                    .stroke(controlColor, lineWidth: 2)
                    .frame(width: 80, height: 80)
                Image(systemName: viewModel.isActive ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(controlColor)
            }
            .shadow(color: controlColor.opacity(0.3), radius: 12)
        }
    }

    private var controlColor: Color {
        viewModel.isActive ? RecallTheme.Colors.neonRed : RecallTheme.Colors.neonCyan
    }

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

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%02d:%02d", mins, secs)
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
}
