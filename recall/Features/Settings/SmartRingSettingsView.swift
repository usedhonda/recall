import SwiftUI
import SmartRingKit

struct SmartRingSettingsView: View {
    @State private var manager = SmartRingManager.shared

    private let accent = RecallTheme.Colors.neonMagenta

    var body: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Smart Ring", color: accent)
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: Binding(
                    get: { manager.isEnabled }, set: { manager.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DIRECT RING SYNC")
                            .font(RecallTheme.Fonts.hudTitle)
                            .foregroundStyle(RecallTheme.Colors.textPrimary)
                        Text("Ring first. Apple Health fills the gaps.")
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.textLabel)
                    }
                }
                .tint(accent)
                .accessibilityLabel("Direct ring sync")

                if manager.isEnabled {
                    Divider().overlay(RecallTheme.Colors.border)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "circle.circle")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(manager.selectedName)
                                .font(RecallTheme.Fonts.hudTitle)
                                .foregroundStyle(RecallTheme.Colors.textPrimary)
                            Text(manager.selectedID == nil ? "SELECT A DEVICE BELOW" : "SELECTED DEVICE")
                                .font(RecallTheme.Fonts.hudMicro)
                                .tracking(1)
                                .foregroundStyle(RecallTheme.Colors.textLabel)
                        }
                        Spacer(minLength: 0)
                        if manager.isBusy {
                            ProgressView().tint(accent)
                                .accessibilityLabel("Ring operation in progress")
                        }
                    }

                    if manager.storedCount > 0 {
                        HStack(spacing: 24) {
                            countLabel("STORED", value: manager.storedCount)
                            countLabel("PENDING ADMISSION", value: manager.pendingCount)
                        }
                    }

                    HUDActionButton(title: "Sync ring now", icon: "arrow.triangle.2.circlepath", color: accent) {
                        manager.sync()
                    }
                    .disabled(manager.isBusy || manager.selectedID == nil || manager.clockTimeZone.isEmpty)
                    .opacity(manager.isBusy || manager.selectedID == nil || manager.clockTimeZone.isEmpty ? 0.4 : 1)
                    .accessibilityLabel("Sync ring now")

                    Text(manager.status)
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textLabel)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let date = manager.lastSyncAt {
                        Text("Last completed read: \(date.formatted())")
                            .font(RecallTheme.Fonts.hudCaption)
                            .foregroundStyle(RecallTheme.Colors.textLabel)
                    }

                    Divider().overlay(RecallTheme.Colors.border)
                    configuration
                    if let estimate = manager.stressSnapshot {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Estimated stress · heart-rate proxy")
                                .font(RecallTheme.Fonts.hudBody)
                            Text(estimate.value.map {
                                "\($0.formatted(.number.precision(.fractionLength(2)))) personal MAD"
                            } ?? "Unavailable: \(estimate.reason ?? "unknown")")
                                .font(RecallTheme.Fonts.hudBody)
                            Text("Unvalidated personal-baseline deviation, not Welly stress or native fatigue. Zero means your baseline, not no stress. Exercise and sleep are not corrected.")
                                .font(RecallTheme.Fonts.hudCaption)
                            if let measuredAt = estimate.inputMeasuredAt {
                                Text("Input measured: \(measuredAt.formatted())")
                                    .font(RecallTheme.Fonts.hudCaption)
                            }
                        }
                        .foregroundStyle(RecallTheme.Colors.textLabel)
                    }
                    research
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Supported ring readings take priority. Apple Health fills missing coverage. Original sources stay separate; nothing is written to Apple Health.")
                        Text("Ring HRV is not HealthKit SDNN. The legacy stress byte is native fatigue, not the vendor app's stress score. Experimental estimates are separate from measurements.")
                        Text("Sync runs on entry, while open, and at iOS background opportunities. Background timing is not guaranteed. Avoid simultaneous vendor-app sync.")
                    }
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textLabel)
                    .lineSpacing(3)
                    .padding(.top, 8)
                } label: {
                    Text("Sources & sync behavior")
                        .font(RecallTheme.Fonts.hudBody)
                        .foregroundStyle(RecallTheme.Colors.textLabel)
                }
                .tint(accent)
            }
            .hudCard(borderColor: manager.isEnabled ? accent.opacity(0.3) : RecallTheme.Colors.border)
        }
    }

    private var configuration: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONFIGURATION")
                .font(RecallTheme.Fonts.hudMicro)
                .tracking(1.5)
                .foregroundStyle(RecallTheme.Colors.textLabel)
            Picker("Ring model", selection: Binding(
                get: { AppSettings.shared.smartRingDeviceModelID },
                set: { AppSettings.shared.smartRingDeviceModelID = $0 }
            )) {
                Text("Unconfirmed model (raw only)").tag("")
                Text("issin Smart Recovery Ring").tag("issin-smart-recovery-ring")
            }
            .font(RecallTheme.Fonts.hudBody)
            .tint(accent)
            .disabled(manager.isBusy)

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    HUDActionButton(title: "Find rings", icon: "antenna.radiowaves.left.and.right", color: accent) {
                        manager.scan()
                    }
                    .disabled(manager.isBusy)
                    .accessibilityLabel("Find rings")
                    ForEach(manager.devices) { device in
                        Button { manager.select(device) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(device.name ?? "Unnamed FFF0 peripheral")
                                        .font(RecallTheme.Fonts.hudBody)
                                    Text(device.id.uuidString)
                                        .font(RecallTheme.Fonts.hudMicro)
                                        .foregroundStyle(RecallTheme.Colors.textLabel)
                                    if device.connectedToSystem {
                                        Text("Already connected to iOS")
                                            .font(RecallTheme.Fonts.hudCaption)
                                            .foregroundStyle(RecallTheme.Colors.textLabel)
                                    }
                                }
                                Spacer(minLength: 0)
                                if manager.selectedID == device.id {
                                    Image(systemName: "checkmark.circle.fill")
                                }
                            }
                            .foregroundStyle(accent)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .disabled(manager.isBusy)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text(manager.selectedID == nil ? "Select a device" : "Change device")
                    .font(RecallTheme.Fonts.hudBody)
                    .foregroundStyle(RecallTheme.Colors.textLabel)
            }
            .tint(accent)
        }
    }

    private func countLabel(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(RecallTheme.Fonts.hudTitle)
                .foregroundStyle(RecallTheme.Colors.textPrimary)
            Text(title).font(RecallTheme.Fonts.hudMicro)
                .foregroundStyle(RecallTheme.Colors.textLabel)
        }
    }

    private var research: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                Text("Unvalidated native-fatigue proxy, not psychological stress. No ring settings are changed. Select a method explicitly; missing data stays unavailable.")
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textLabel)
                Picker("Estimation method", selection: Binding(
                    get: { AppSettings.shared.smartRingFatigueMethod },
                    set: { manager.setFatigueMethod($0) }
                )) {
                    Text("Off").tag("")
                    Text("Carry forward (estimated hold)").tag("carryForward")
                    Text("Regression").tag("unanchored")
                    Text("Full residual").tag("fullResidual")
                    Text("Learned decay").tag("learnedDecay")
                }
                .disabled(manager.isBusy)
                .tint(accent)
                Text(manager.fatigueAnalysisStatus)
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textLabel)
                if let estimate = manager.fatigueEstimate {
                    Text(estimate.value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) raw / \(estimate.status)" } ?? "No estimate")
                        .font(RecallTheme.Fonts.hudBody)
                    Text("As of \(estimate.asOf.formatted()) / experimental, unvalidated")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textLabel)
                }
                if let inputs = manager.researchInputs {
                    Text("Research inputs: \(inputs.contexts.filter { $0.withinAgeLimit && !$0.isConflicting }.count) fresh categories; \(inputs.missingCommands.count) missing. Source age limit: 10 minutes. Radio coverage is tracked separately.")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textLabel)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Experimental native fatigue")
                .font(RecallTheme.Fonts.hudBody)
                .foregroundStyle(RecallTheme.Colors.textLabel)
        }
        .tint(accent)
    }

}
