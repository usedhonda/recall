import SwiftUI

struct SmartRingSettingsView: View {
    @State private var manager = SmartRingManager.shared

    var body: some View {
        VStack(spacing: 8) {
            HUDSectionHeader(title: "Smart Ring", color: RecallTheme.Colors.neonMagenta)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Direct ring sync", isOn: Binding(
                    get: { manager.isEnabled }, set: { manager.setEnabled($0) }
                ))
                .tint(RecallTheme.Colors.neonMagenta)

                Text("One health snapshot combines both sources. Direct ring heart rate is preferred within the Health reading interval; Apple Health fills other metrics. Original source records are retained. Ring HRV and stress remain labelled raw values, never HealthKit SDNN. Nothing is written to Apple Health.")
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)

                if manager.isEnabled {
                    Text(manager.selectedName).font(RecallTheme.Fonts.hudBody)
                    Button("Find rings") { manager.scan() }.disabled(manager.isBusy)
                    ForEach(manager.devices) { device in
                        Button { manager.select(device) } label: {
                            VStack(alignment: .leading) {
                                Text(device.name ?? "Unnamed FFF0 peripheral")
                                Text(device.id.uuidString).font(.caption2)
                                if device.connectedToSystem { Text("Already connected to iOS").font(.caption) }
                            }
                        }.disabled(manager.isBusy)
                    }
                    Picker("Ring clock time zone", selection: Binding(
                        get: { manager.clockTimeZone }, set: { manager.setClockTimeZone($0) }
                    )) {
                        Text("Choose time zone").tag("")
                        ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
                    }.disabled(manager.isBusy)
                    Text("Choose the time zone used by the ring's clock. Historical travel or clock changes cannot be inferred. HRV units and stress scale are unverified.")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                    Button("Sync ring now") { manager.sync() }
                        .disabled(manager.isBusy || manager.selectedID == nil || manager.clockTimeZone.isEmpty)
                    Text("Syncs on foreground entry and every 15 minutes while open. Continuous background sync and simultaneous vendor-app reads are unverified.")
                        .font(RecallTheme.Fonts.hudCaption)
                        .foregroundStyle(RecallTheme.Colors.textSecondary)
                }
                Text(manager.status)
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                if let date = manager.lastSyncAt {
                    Text("Last ring read: \(date.formatted())").font(RecallTheme.Fonts.hudCaption)
                }
            }
            .hudCard()
        }
    }
}
