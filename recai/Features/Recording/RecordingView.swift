import SwiftUI
import SwiftData

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = RecordingViewModel()
    private var telemetry = TelemetryService.shared

    private var modelContainer: ModelContainer? {
        modelContext.container
    }

    @State private var showLog = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                dataStreamsBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                stateIndicator

                metersSection

                chunkInfo

                controlButton

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                // Activity Log
                VStack(spacing: 4) {
                    HStack {
                        Text("Activity Log")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            showLog.toggle()
                        } label: {
                            Image(systemName: showLog ? "chevron.down" : "chevron.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button {
                            ActivityLogger.shared.clear()
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)

                    if showLog {
                        ActivityLogView(entries: ActivityLogger.shared.entries)
                            .frame(maxHeight: .infinity)
                            .background(Color(.systemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .padding(.horizontal, 8)
                    }
                }
            }
            .navigationTitle("Recording")
            .task {
                if let container = modelContainer {
                    await viewModel.start(modelContainer: container)
                }
            }
        }
    }

    @ViewBuilder
    private var stateIndicator: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 16, height: 16)
                .overlay {
                    if viewModel.isRecording {
                        Circle()
                            .fill(stateColor.opacity(0.4))
                            .frame(width: 24, height: 24)
                    }
                }

            Text(stateText)
                .font(.title2)
                .fontWeight(.medium)
        }
    }

    @ViewBuilder
    private var metersSection: some View {
        VStack(spacing: 16) {
            meterRow(label: "RMS", value: viewModel.currentRMS, threshold: AppSettings.shared.rmsThreshold)
            meterRow(label: "VAD", value: viewModel.vadProbability, threshold: AppSettings.shared.vadThreshold)
        }
        .padding(.horizontal, 32)
    }

    @ViewBuilder
    private func meterRow(label: String, value: Float, threshold: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.3f", value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.2))

                    Capsule()
                        .fill(value > threshold ? Color.green : Color.blue)
                        .frame(width: max(0, geo.size.width * CGFloat(min(value, 1.0))))

                    Rectangle()
                        .fill(Color.orange)
                        .frame(width: 2)
                        .offset(x: geo.size.width * CGFloat(threshold))
                }
            }
            .frame(height: 8)
        }
    }

    @ViewBuilder
    private var chunkInfo: some View {
        VStack(spacing: 8) {
            Text("Chunks: \(viewModel.chunksRecorded)")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if viewModel.isRecording {
                Text("Duration: \(formatDuration(viewModel.currentChunkDuration))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
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
            Image(systemName: viewModel.isActive ? "stop.circle.fill" : "mic.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(viewModel.isActive ? .red : .blue)
        }
    }

    private var stateColor: Color {
        switch viewModel.state {
        case .idle: .gray
        case .listening: .blue
        case .recording: .red
        case .paused: .orange
        }
    }

    private var stateText: String {
        switch viewModel.state {
        case .idle: "Idle"
        case .listening: "Listening"
        case .recording: "Recording"
        case .paused: "Paused"
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    // MARK: - Data Streams Bar

    @ViewBuilder
    private var dataStreamsBar: some View {
        HStack(spacing: 16) {
            StreamToggle(
                icon: "mic.fill",
                label: "Audio",
                isActive: viewModel.isActive,
                color: .blue
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

            StreamToggle(
                icon: "location.fill",
                label: "Location",
                isActive: telemetry.locationManager.isUpdating,
                color: .cyan
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

            StreamToggle(
                icon: "heart.fill",
                label: "Health",
                isActive: telemetry.healthManager.isEnabled,
                color: .pink
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

// MARK: - Stream Toggle Component

private struct StreamToggle: View {
    let icon: String
    let label: String
    let isActive: Bool
    let color: Color
    var needsSetup: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title2)
                Text(label)
                    .font(.caption2)
                Text(isActive ? "ON" : "OFF")
                    .font(.caption2.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isActive ? color.opacity(0.15) : Color.secondary.opacity(0.1))
            )
            .foregroundStyle(isActive ? color : .secondary)
            .overlay {
                if needsSetup {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.yellow, lineWidth: 1.5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
