import HealthKit
import Observation
import SwiftUI

@MainActor
@Observable
final class HealthKitInspectorViewModel {
    var reports: [HealthKitInspector.TypeReport] = []
    var extendedAuthorized = false
    var sampleExamples: [String: [String]] = [:]
    var expandedIdentifiers: Set<String> = []
    var isScanning = false
    var isAuthorizingExtended = false
    var statusMessage: String?

    private let inspector = HealthKitInspector()

    func scan() async {
        isScanning = true
        defer { isScanning = false }
        reports = await inspector.scan(includeExtended: extendedAuthorized)
        statusMessage = "Scanned \(reports.count) types"
    }

    func requestExtendedAuth() async {
        isAuthorizingExtended = true
        defer { isAuthorizingExtended = false }

        let granted = await inspector.requestExtendedAuthorization()
        extendedAuthorized = granted
        statusMessage = granted ? "Extended auth granted" : "Extended auth denied"
    }

    func toggleExpansion(for identifier: String) {
        if expandedIdentifiers.contains(identifier) {
            expandedIdentifiers.remove(identifier)
        } else {
            expandedIdentifiers.insert(identifier)
        }
    }

    func loadExamplesIfNeeded(for identifier: String) async {
        guard sampleExamples[identifier] == nil else { return }
        sampleExamples[identifier] = await inspector.fetchSampleExamples(identifier: identifier)
    }

    func dumpToLog() {
        for report in reports {
            let latest = report.latestEnd?.formatted(.dateTime.year().month().day().hour().minute()) ?? "-"
            let value = report.latestValue ?? "-"
            let sourceName = report.latestSourceName ?? "-"
            let sourceBundleId = report.latestSourceBundleId ?? "-"
            ActivityLogger.shared.log(
                .health,
                "Inspector: \(report.identifier) auth=\(report.authorizationStatus.debugLabel) count=\(report.sampleCount7d) latest=\(latest) value=\(value) src=\(sourceName)(\(sourceBundleId))"
            )
        }
        statusMessage = "Dumped \(reports.count) rows to log"
    }
}

struct HealthKitInspectorView: View {
    @State private var viewModel = HealthKitInspectorViewModel()

    var body: some View {
        List {
            controlsSection
            reportsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("HealthKit Inspector")
        .task {
            if viewModel.reports.isEmpty {
                await viewModel.scan()
            }
        }
    }

    private var controlsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(viewModel.isScanning ? "Scanning..." : "Scan") {
                        Task { await viewModel.scan() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isScanning)

                    Button(viewModel.isAuthorizingExtended ? "Authorizing..." : "Request Extended Auth") {
                        Task { await viewModel.requestExtendedAuth() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.isAuthorizingExtended)
                }

                HStack(spacing: 12) {
                    Button("Dump to Log") {
                        viewModel.dumpToLog()
                    }
                    .buttonStyle(.bordered)

                    if viewModel.extendedAuthorized {
                        Text("Extended enabled")
                            .font(.caption.monospaced())
                            .foregroundStyle(.green)
                    }
                }

                if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Controls")
        }
    }

    private var reportsSection: some View {
        Section {
            if viewModel.reports.isEmpty, !viewModel.isScanning {
                Text("No reports yet")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.reports) { report in
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { viewModel.expandedIdentifiers.contains(report.identifier) },
                            set: { expanded in
                                if expanded {
                                    viewModel.expandedIdentifiers.insert(report.identifier)
                                    Task { await viewModel.loadExamplesIfNeeded(for: report.identifier) }
                                } else {
                                    viewModel.expandedIdentifiers.remove(report.identifier)
                                }
                            }
                        )
                    ) {
                        VStack(alignment: .leading, spacing: 8) {
                            inspectorDetailRow("AUTH", report.authorizationStatus.debugLabel)
                            inspectorDetailRow("SOURCE", report.latestSourceName ?? "-")
                            inspectorDetailRow("BUNDLE", report.latestSourceBundleId ?? "-")
                            inspectorDetailRow("START", formatted(report.latestStart))
                            inspectorDetailRow("END", formatted(report.latestEnd))
                            inspectorDetailRow("VALUE", report.latestValue ?? "-")

                            if let examples = viewModel.sampleExamples[report.identifier], !examples.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("EXAMPLES")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                    ForEach(Array(examples.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.primary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(report.authorizationStatus.needsAttention ? "!" : "·")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(report.authorizationStatus.needsAttention ? RecallTheme.Colors.neonAmber : RecallTheme.Colors.textSecondary)
                                Text(report.identifier)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text("\(report.sampleCount7d)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(RecallTheme.Colors.neonCyan)
                            }
                            HStack {
                                Text(report.latestValue ?? "-")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text(formatted(report.latestEnd))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Types")
        }
    }

    private func inspectorDetailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "-" }
        return date.formatted(.dateTime.year().month().day().hour().minute())
    }
}

private extension HKAuthorizationStatus {
    var debugLabel: String {
        switch self {
        case .notDetermined:
            return "notDetermined"
        case .sharingDenied:
            return "sharingDenied"
        case .sharingAuthorized:
            return "sharingAuthorized"
        @unknown default:
            return "unknown"
        }
    }

    var needsAttention: Bool {
        self != .sharingAuthorized
    }
}
