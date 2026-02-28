import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HUDHeaderBar(title: "Config")

            ScrollView {
                VStack(spacing: 16) {
                    vadSection
                    recordingSection
                    uploadSection
                    storageSection
                    telemetryServerSection
                    healthSection
                    locationSection
                    deviceSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
        .background(RecallTheme.Colors.bg)
    }

    // MARK: - VAD

    @ViewBuilder
    private var vadSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Voice Detection")
            VStack(spacing: 12) {
                hudSlider(
                    label: "RMS THRESHOLD",
                    value: String(format: "%.3f", viewModel.rmsThreshold),
                    binding: $viewModel.rmsThreshold,
                    range: 0.001...0.1,
                    step: 0.001
                )
                hudSlider(
                    label: "VAD THRESHOLD",
                    value: String(format: "%.2f", viewModel.vadThreshold),
                    binding: $viewModel.vadThreshold,
                    range: 0.1...0.95,
                    step: 0.05
                )
                hudSlider(
                    label: "SILENCE TIMEOUT",
                    value: String(format: "%.0fs", viewModel.silenceTimeout),
                    binding: $viewModel.silenceTimeout,
                    range: 1...10,
                    step: 0.5
                )
            }
            .hudCard()
        }
    }

    // MARK: - Recording

    @ViewBuilder
    private var recordingSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Recording")
            VStack(spacing: 12) {
                hudSlider(
                    label: "PRE-MARGIN",
                    value: String(format: "%.1fs", viewModel.preMargin),
                    binding: $viewModel.preMargin,
                    range: 0.5...5.0,
                    step: 0.5
                )
                hudSlider(
                    label: "POST-MARGIN",
                    value: String(format: "%.1fs", viewModel.postMargin),
                    binding: $viewModel.postMargin,
                    range: 0.5...5.0,
                    step: 0.5
                )
                hudSlider(
                    label: "CHUNK DURATION",
                    value: String(format: "%.0fs", viewModel.chunkDuration),
                    binding: $viewModel.chunkDuration,
                    range: 60...600,
                    step: 30
                )
            }
            .hudCard()
        }
    }

    // MARK: - Upload

    @ViewBuilder
    private var uploadSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Upload")
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SERVER URL")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                    TextField("", text: $viewModel.serverURL)
                        .font(RecallTheme.Fonts.hudBody)
                        .foregroundStyle(RecallTheme.Colors.textPrimary)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .padding(8)
                        .background(RecallTheme.Colors.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(RecallTheme.Colors.border, lineWidth: 1)
                        )
                }
                hudToggle(label: "WIFI ONLY", isOn: $viewModel.wifiOnly)
            }
            .hudCard()
        }
    }

    // MARK: - Storage

    @ViewBuilder
    private var storageSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Storage")
            VStack(spacing: 12) {
                hudSlider(
                    label: "STORAGE CAP",
                    value: "\(viewModel.storageCap) MB",
                    binding: Binding(
                        get: { Double(viewModel.storageCap) },
                        set: { viewModel.storageCap = Int($0) }
                    ),
                    range: 256...4096,
                    step: 256
                )
            }
            .hudCard()
        }
    }

    // MARK: - Telemetry Server

    @ViewBuilder
    private var telemetryServerSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Telemetry Server")
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SERVER URL")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                    TextField("", text: $viewModel.telemetryServerURL)
                        .font(RecallTheme.Fonts.hudBody)
                        .foregroundStyle(RecallTheme.Colors.textPrimary)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .padding(8)
                        .background(RecallTheme.Colors.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(RecallTheme.Colors.border, lineWidth: 1)
                        )
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("BEARER TOKEN")
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.textSecondary)
                        SecureField("", text: $viewModel.tokenInput)
                            .font(RecallTheme.Fonts.hudBody)
                            .foregroundStyle(RecallTheme.Colors.textPrimary)
                            .textContentType(.password)
                            .padding(8)
                            .background(RecallTheme.Colors.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(RecallTheme.Colors.border, lineWidth: 1)
                            )
                    }
                    if viewModel.hasToken {
                        Button("DELETE") {
                            viewModel.deleteToken()
                        }
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.neonRed)
                    } else {
                        Button("SAVE") {
                            viewModel.saveToken()
                        }
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.neonGreen)
                        .disabled(viewModel.tokenInput.isEmpty)
                    }
                }

                HStack {
                    Text("STATUS")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                    Spacer()
                    if viewModel.isTestingConnection {
                        ProgressView()
                            .controlSize(.small)
                            .tint(RecallTheme.Colors.neonCyan)
                    } else {
                        Text(viewModel.hasValidConfig ? "CONFIGURED" : "NOT CONFIGURED")
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(viewModel.hasValidConfig ? RecallTheme.Colors.neonGreen : RecallTheme.Colors.textMuted)
                    }
                }

                HUDActionButton(
                    title: "Test Connection",
                    icon: "antenna.radiowaves.left.and.right",
                    color: RecallTheme.Colors.neonCyan
                ) {
                    Task { await viewModel.testConnection() }
                }
                .opacity(viewModel.hasValidConfig && !viewModel.isTestingConnection ? 1.0 : 0.4)
                .disabled(!viewModel.hasValidConfig || viewModel.isTestingConnection)

                if let result = viewModel.connectionTestResult {
                    Text(result)
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(result.contains("OK") ? RecallTheme.Colors.neonGreen : RecallTheme.Colors.neonRed)
                }
            }
            .hudCard()
        }
    }

    // MARK: - Health

    @ViewBuilder
    private var healthSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Health Data", color: RecallTheme.Colors.neonMagenta)
            VStack(spacing: 12) {
                hudToggle(label: "HEALTH ENABLED", isOn: $viewModel.healthEnabled)

                if let lastQuery = viewModel.lastHealthQueryTime {
                    HStack {
                        Text("LAST QUERY")
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.textSecondary)
                        Spacer()
                        Text(lastQuery, style: .relative)
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.neonMagenta.opacity(0.7))
                    }
                }
            }
            .hudCard()
        }
    }

    // MARK: - Location

    @ViewBuilder
    private var locationSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Location")
            VStack(spacing: 12) {
                hudToggle(label: "LOCATION ENABLED", isOn: $viewModel.locationEnabled)
                hudToggle(label: "BACKGROUND LOCATION", isOn: $viewModel.locationBackgroundEnabled)
                    .opacity(viewModel.locationEnabled ? 1.0 : 0.4)
                    .disabled(!viewModel.locationEnabled)

                hudSlider(
                    label: "SEND INTERVAL",
                    value: "\(Int(viewModel.telemetrySendInterval))s",
                    binding: $viewModel.telemetrySendInterval,
                    range: 15...300,
                    step: 5
                )
                .opacity(viewModel.locationEnabled ? 1.0 : 0.4)
                .disabled(!viewModel.locationEnabled)

                if let lastSent = viewModel.lastLocationSentTime {
                    HStack {
                        Text("LAST SENT")
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.textSecondary)
                        Spacer()
                        Text(lastSent, style: .relative)
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.neonCyan.opacity(0.7))
                    }
                }
            }
            .hudCard()
        }
    }

    // MARK: - Device

    @ViewBuilder
    private var deviceSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Device")
            HStack {
                Text("DEVICE ID")
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                Spacer()
                Text(viewModel.deviceId)
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
            .hudCard()
        }
    }

    // MARK: - Reusable Controls

    @ViewBuilder
    private func hudSlider(
        label: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                Spacer()
                Text(value)
                    .font(RecallTheme.Fonts.hudMeter)
                    .foregroundStyle(RecallTheme.Colors.neonCyan)
            }
            Slider(value: binding, in: range, step: step)
                .tint(RecallTheme.Colors.neonCyan)
        }
    }

    @ViewBuilder
    private func hudSlider(
        label: String,
        value: String,
        binding: Binding<Float>,
        range: ClosedRange<Float>,
        step: Float
    ) -> some View {
        let doubleBinding = Binding<Double>(
            get: { Double(binding.wrappedValue) },
            set: { binding.wrappedValue = Float($0) }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                Spacer()
                Text(value)
                    .font(RecallTheme.Fonts.hudMeter)
                    .foregroundStyle(RecallTheme.Colors.neonCyan)
            }
            Slider(value: doubleBinding, in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step))
                .tint(RecallTheme.Colors.neonCyan)
        }
    }

    @ViewBuilder
    private func hudToggle(label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(RecallTheme.Fonts.hudCaption)
                .foregroundStyle(RecallTheme.Colors.textSecondary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(RecallTheme.Colors.neonGreen)
        }
    }
}
