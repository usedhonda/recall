import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                vadSection
                recordingSection
                uploadSection
                storageSection
                deviceSection
            }
            .navigationTitle("Settings")
        }
    }

    @ViewBuilder
    private var vadSection: some View {
        Section("Voice Detection") {
            VStack(alignment: .leading) {
                Text("RMS Threshold: \(String(format: "%.3f", viewModel.rmsThreshold))")
                Slider(value: $viewModel.rmsThreshold, in: 0.001...0.1, step: 0.001)
            }
            VStack(alignment: .leading) {
                Text("VAD Threshold: \(String(format: "%.2f", viewModel.vadThreshold))")
                Slider(value: $viewModel.vadThreshold, in: 0.1...0.95, step: 0.05)
            }
            VStack(alignment: .leading) {
                Text("Silence Timeout: \(String(format: "%.0fs", viewModel.silenceTimeout))")
                Slider(value: $viewModel.silenceTimeout, in: 1...10, step: 0.5)
            }
        }
    }

    @ViewBuilder
    private var recordingSection: some View {
        Section("Recording") {
            VStack(alignment: .leading) {
                Text("Pre-margin: \(String(format: "%.1fs", viewModel.preMargin))")
                Slider(value: $viewModel.preMargin, in: 0.5...5.0, step: 0.5)
            }
            VStack(alignment: .leading) {
                Text("Post-margin: \(String(format: "%.1fs", viewModel.postMargin))")
                Slider(value: $viewModel.postMargin, in: 0.5...5.0, step: 0.5)
            }
            VStack(alignment: .leading) {
                Text("Chunk Duration: \(String(format: "%.0fs", viewModel.chunkDuration))")
                Slider(value: $viewModel.chunkDuration, in: 60...600, step: 30)
            }
        }
    }

    @ViewBuilder
    private var uploadSection: some View {
        Section("Upload") {
            TextField("Server URL", text: $viewModel.serverURL)
                .textContentType(.URL)
                .autocapitalization(.none)
                .keyboardType(.URL)
            Toggle("WiFi Only", isOn: $viewModel.wifiOnly)
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section("Storage") {
            VStack(alignment: .leading) {
                Text("Storage Cap: \(viewModel.storageCap) MB")
                Slider(value: Binding(
                    get: { Double(viewModel.storageCap) },
                    set: { viewModel.storageCap = Int($0) }
                ), in: 256...4096, step: 256)
            }
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        Section("Device") {
            HStack {
                Text("Device ID")
                Spacer()
                Text(viewModel.deviceId)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
