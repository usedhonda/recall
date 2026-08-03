import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HUDHeaderBar(title: "Config")

            ScrollView {
                VStack(spacing: 16) {
                    telemetryServerSection
                    chiTriggersSection
                    reactionModeSection
                    chiDeliverySection
                    networkSection
                    storageSection
                    healthSection
                    locationSection
                    deviceSection
#if DEBUG
                    debugSection
#endif
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
        }
        .background(RecallTheme.Colors.bg)
        .sheet(isPresented: $viewModel.showQRScanner) {
            QRScannerView { code in
                _ = viewModel.applyQRCode(code)
            }
        }
    }

    // MARK: - Network

    @ViewBuilder
    private var networkSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Network")
            VStack(spacing: 12) {
                Text("DATA POLICY")
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(DataPolicy.allCases, id: \.self) { policy in
                    hudPolicyRow(policy: policy)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("HOME WIFI SSID")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                    TextField("", text: $viewModel.homeSSID)
                        .font(RecallTheme.Fonts.hudBody)
                        .foregroundStyle(RecallTheme.Colors.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(8)
                        .background(RecallTheme.Colors.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(RecallTheme.Colors.border, lineWidth: 1)
                        )
                }
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
                    title: "Scan QR Code",
                    icon: "qrcode.viewfinder",
                    color: RecallTheme.Colors.neonGreen
                ) {
                    viewModel.showQRScanner = true
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

                if let qrResult = viewModel.qrScanResult {
                    Text(qrResult)
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.neonGreen)
                }
            }
            .hudCard()
        }
    }

    // MARK: - Reaction Triggers

    @ViewBuilder
    private var chiTriggersSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Reaction Triggers", color: RecallTheme.Colors.neonMagenta)
            VStack(spacing: 12) {
                hudToggle(label: "WEB REACTIONS", isOn: $viewModel.webReactionsEnabled)
                hudToggle(label: "VOICE REACTIONS", isOn: $viewModel.voiceReactionsEnabled)
                hudSlider(
                    label: "MIN CONTENT (NON-X)",
                    value: "\(viewModel.webMinContentChars)",
                    binding: Binding(
                        get: { Double(viewModel.webMinContentChars) },
                        set: { viewModel.webMinContentChars = Int($0) }
                    ),
                    range: 0...1000,
                    step: 50
                )
            }
            .hudCard()
        }
    }

    // MARK: - Reaction Mode

    @ViewBuilder
    private var reactionModeSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Reaction Mode", color: RecallTheme.Colors.neonMagenta)
            VStack(spacing: 12) {
                Text("CHI STANCE")
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(ReactionMode.allCases, id: \.self) { mode in
                    hudReactionModeRow(mode: mode)
                }
            }
            .hudCard()
        }
    }

    // MARK: - Reaction Delivery

    @ViewBuilder
    private var chiDeliverySection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Reaction Delivery", color: RecallTheme.Colors.neonMagenta)
            VStack(spacing: 12) {
                hudToggle(label: "LINE", isOn: $viewModel.lineDeliveryEnabled)
                hudToggle(label: "VIBETERM", isOn: $viewModel.vibetermDeliveryEnabled)
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

                Divider()
                    .overlay(RecallTheme.Colors.border)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ANCHORS")
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.textSecondary)
                        Spacer()
                        Text("\(viewModel.locationAnchors.count)")
                            .font(RecallTheme.Fonts.hudMeter)
                            .foregroundStyle(RecallTheme.Colors.neonCyan)
                    }

                    if viewModel.locationAnchors.isEmpty {
                        Text("ADD CURRENT LOCATION TO ENABLE OS REGION ARRIVAL/EXIT WAKES")
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.textMuted)
                    } else {
                        ForEach(viewModel.locationAnchors) { anchor in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(anchor.name.uppercased())
                                        .font(RecallTheme.Fonts.hudCaption)
                                        .foregroundStyle(RecallTheme.Colors.textPrimary)
                                    Text(String(format: "%.5f, %.5f / %.0fm", anchor.latitude, anchor.longitude, anchor.radius))
                                        .font(RecallTheme.Fonts.hudCaption)
                                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                                }
                                Spacer()
                                Button("DELETE") {
                                    viewModel.deleteAnchor(id: anchor.id)
                                }
                                .font(RecallTheme.Fonts.hudCaption)
                                .foregroundStyle(RecallTheme.Colors.neonRed)
                            }
                            .padding(8)
                            .background(RecallTheme.Colors.surfaceAlt)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    viewModel.deleteAnchor(id: anchor.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }

                    TextField("anchor name", text: $viewModel.newAnchorName)
                        .font(RecallTheme.Fonts.hudBody)
                        .foregroundStyle(RecallTheme.Colors.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(8)
                        .background(RecallTheme.Colors.surfaceAlt)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(RecallTheme.Colors.border, lineWidth: 1)
                        )

                    hudSlider(
                        label: "ANCHOR RADIUS",
                        value: "\(Int(viewModel.newAnchorRadius))m",
                        binding: $viewModel.newAnchorRadius,
                        range: 25...200,
                        step: 5
                    )

                    HUDActionButton(
                        title: "Add Current Location",
                        icon: "location.circle",
                        color: RecallTheme.Colors.neonCyan
                    ) {
                        viewModel.addAnchorFromCurrentLocation()
                    }
                    .opacity(viewModel.currentLocation == nil ? 0.4 : 1.0)
                    .disabled(viewModel.currentLocation == nil)
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

#if DEBUG
    // MARK: - Debug

    @ViewBuilder
    private var debugSection: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Debug", color: RecallTheme.Colors.neonAmber)
            NavigationLink {
                HealthKitInspectorView()
            } label: {
                HStack {
                    Text("HEALTHKIT INSPECTOR")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.neonAmber)
                }
            }
            .hudCard(borderColor: RecallTheme.Colors.neonAmber.opacity(0.35))
        }
    }
#endif

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

    private func hudPolicyRow(policy: DataPolicy) -> some View {
        Button {
            viewModel.dataPolicy = policy
        } label: {
            HStack {
                Text(policy.displayLabel)
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(viewModel.dataPolicy == policy ? RecallTheme.Colors.neonGreen : RecallTheme.Colors.textSecondary)
                Spacer()
                if viewModel.dataPolicy == policy {
                    Image(systemName: "checkmark")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.neonGreen)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func hudReactionModeRow(mode: ReactionMode) -> some View {
        Button {
            viewModel.reactionMode = mode
        } label: {
            HStack {
                Text(mode.displayLabel)
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(viewModel.reactionMode == mode ? RecallTheme.Colors.neonGreen : RecallTheme.Colors.textSecondary)
                Spacer()
                if viewModel.reactionMode == mode {
                    Image(systemName: "checkmark")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.neonGreen)
                }
            }
        }
        .buttonStyle(.plain)
    }
}
