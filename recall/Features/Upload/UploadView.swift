import SwiftUI
import SwiftData

struct UploadView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = UploadViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HUDHeaderBar(title: "Upload Queue")

            ScrollView {
                VStack(spacing: 12) {
                    // Status Section
                    VStack(spacing: 8) {
                        HUDSectionHeader(title: "Status")
                        VStack(spacing: 6) {
                            statusRow(
                                label: "SERVER",
                                value: viewModel.hasServerURL ? AppSettings.shared.uploadServerURL : "NOT CONFIGURED",
                                color: viewModel.hasServerURL ? RecallTheme.Colors.neonCyan : RecallTheme.Colors.neonRed
                            )
                            networkRow
                            if viewModel.isUploading {
                                statusRow(
                                    label: "PROGRESS",
                                    value: viewModel.uploadProgress,
                                    color: RecallTheme.Colors.neonCyan
                                )
                            }
                        }
                        .hudCard()
                    }
                    .padding(.horizontal, 12)

                    // Counts Section
                    VStack(spacing: 8) {
                        HUDSectionHeader(title: "Chunks")
                            .padding(.horizontal, 12)
                        HStack(spacing: 8) {
                            countCard(
                                icon: "clock",
                                label: "PENDING",
                                count: viewModel.pendingCount,
                                color: RecallTheme.Colors.neonAmber
                            )
                            countCard(
                                icon: "checkmark",
                                label: "UPLOADED",
                                count: viewModel.uploadedCount,
                                color: RecallTheme.Colors.neonGreen
                            )
                            countCard(
                                icon: "exclamationmark.triangle",
                                label: "FAILED",
                                count: viewModel.failedCount,
                                color: RecallTheme.Colors.neonRed
                            )
                        }
                        .padding(.horizontal, 12)
                    }

                    // Actions Section
                    VStack(spacing: 8) {
                        HUDSectionHeader(title: "Actions")
                            .padding(.horizontal, 12)

                        VStack(spacing: 8) {
                            HUDActionButton(
                                title: viewModel.isUploading ? "Stop Upload" : "Start Upload",
                                icon: viewModel.isUploading ? "stop.circle" : "arrow.up.circle",
                                color: viewModel.isUploading ? RecallTheme.Colors.neonRed : RecallTheme.Colors.neonCyan
                            ) {
                                if viewModel.isUploading {
                                    viewModel.stopUploading()
                                } else {
                                    viewModel.startUploading(modelContext: modelContext)
                                }
                            }
                            .opacity(viewModel.hasServerURL ? 1.0 : 0.4)
                            .disabled(!viewModel.hasServerURL)

                            if viewModel.failedCount > 0 {
                                HUDActionButton(
                                    title: "Retry Failed",
                                    icon: "arrow.clockwise",
                                    color: RecallTheme.Colors.neonAmber
                                ) {
                                    viewModel.retryFailed(modelContext: modelContext)
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 12)
            }
        }
        .background(RecallTheme.Colors.bg)
        .onAppear {
            viewModel.refreshCounts(modelContext: modelContext)
        }
    }

    @ViewBuilder
    private func statusRow(label: String, value: String, color: Color) -> some View {
        HStack {
            Text(label)
                .font(RecallTheme.Fonts.hudCaption)
                .foregroundStyle(RecallTheme.Colors.textSecondary)
            Spacer()
            Text(value)
                .font(RecallTheme.Fonts.hudBody)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var networkRow: some View {
        HStack {
            Text("NETWORK")
                .font(RecallTheme.Fonts.hudCaption)
                .foregroundStyle(RecallTheme.Colors.textSecondary)
            Spacer()
            let monitor = ConnectivityMonitor.shared
            if monitor.isWiFi {
                Label("WIFI", systemImage: "wifi")
                    .font(RecallTheme.Fonts.hudBody)
                    .foregroundStyle(RecallTheme.Colors.neonGreen)
            } else if monitor.isCellular {
                Label("CELLULAR", systemImage: "antenna.radiowaves.left.and.right")
                    .font(RecallTheme.Fonts.hudBody)
                    .foregroundStyle(RecallTheme.Colors.neonAmber)
            } else {
                Label("OFFLINE", systemImage: "wifi.slash")
                    .font(RecallTheme.Fonts.hudBody)
                    .foregroundStyle(RecallTheme.Colors.neonRed)
            }
        }
    }

    @ViewBuilder
    private func countCard(icon: String, label: String, count: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(RecallTheme.Fonts.hudBody)
                .foregroundStyle(color)
            Text("\(count)")
                .font(RecallTheme.Fonts.hudLarge)
                .foregroundStyle(color)
            Text(label)
                .font(RecallTheme.Fonts.hudMicro)
                .foregroundStyle(RecallTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .hudCard(borderColor: color.opacity(0.3))
    }
}
