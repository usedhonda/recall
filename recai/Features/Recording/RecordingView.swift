import SwiftUI
import SwiftData

struct RecordingView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = RecordingViewModel()

    private var modelContainer: ModelContainer? {
        modelContext.container
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                stateIndicator

                metersSection

                chunkInfo

                Spacer()

                controlButton

                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }

                Spacer()
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
}
