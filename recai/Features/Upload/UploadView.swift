import SwiftUI
import SwiftData

struct UploadView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = UploadViewModel()

    var body: some View {
        NavigationStack {
            List {
                statusSection
                countsSection
                actionsSection
            }
            .navigationTitle("Upload")
            .onAppear {
                viewModel.refreshCounts(modelContext: modelContext)
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            HStack {
                Text("Server")
                Spacer()
                if viewModel.hasServerURL {
                    Text(AppSettings.shared.uploadServerURL)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not configured")
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Text("Network")
                Spacer()
                let monitor = ConnectivityMonitor.shared
                if monitor.isWiFi {
                    Label("WiFi", systemImage: "wifi")
                        .foregroundStyle(.green)
                } else if monitor.isCellular {
                    Label("Cellular", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.orange)
                } else {
                    Label("Offline", systemImage: "wifi.slash")
                        .foregroundStyle(.red)
                }
            }

            if viewModel.isUploading {
                HStack {
                    Text("Progress")
                    Spacer()
                    Text(viewModel.uploadProgress)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var countsSection: some View {
        Section("Chunks") {
            HStack {
                Label("Pending", systemImage: "clock")
                Spacer()
                Text("\(viewModel.pendingCount)")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Label("Uploaded", systemImage: "checkmark.circle")
                Spacer()
                Text("\(viewModel.uploadedCount)")
                    .foregroundStyle(.green)
            }
            HStack {
                Label("Failed", systemImage: "exclamationmark.triangle")
                Spacer()
                Text("\(viewModel.failedCount)")
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        Section {
            Button {
                if viewModel.isUploading {
                    viewModel.stopUploading()
                } else {
                    viewModel.startUploading(modelContext: modelContext)
                }
            } label: {
                Label(
                    viewModel.isUploading ? "Stop Upload" : "Start Upload",
                    systemImage: viewModel.isUploading ? "stop.circle" : "arrow.up.circle"
                )
            }
            .disabled(!viewModel.hasServerURL)

            if viewModel.failedCount > 0 {
                Button {
                    viewModel.retryFailed(modelContext: modelContext)
                } label: {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
            }
        }
    }
}
