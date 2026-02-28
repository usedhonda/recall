import SwiftUI

struct ActivityLogView: View {
    let entries: [ActivityLogger.Entry]
    var maxVisible: Int = 50

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let visible = entries.suffix(maxVisible)
                    ForEach(visible) { entry in
                        HStack(spacing: 6) {
                            Text(Self.timeFormatter.string(from: entry.timestamp))
                                .font(RecallTheme.Fonts.hudMicro)
                                .foregroundStyle(RecallTheme.Colors.textSecondary)
                            Text("[\(entry.category.emoji)]")
                                .font(RecallTheme.Fonts.hudMicro)
                                .foregroundStyle(color(for: entry.category))
                            Text(entry.message)
                                .font(RecallTheme.Fonts.hudMicro)
                                .foregroundStyle(color(for: entry.category))
                        }
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .background(RecallTheme.Colors.surface)
            .mask(
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.clear, .white],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)
                    Rectangle().fill(Color.white)
                }
            )
            .onChange(of: entries.count) {
                if let last = entries.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for category: ActivityLogger.Entry.Category) -> Color {
        switch category {
        case .state: RecallTheme.Colors.textPrimary
        case .vad: RecallTheme.Colors.neonCyan
        case .chunk: RecallTheme.Colors.neonGreen
        case .upload: RecallTheme.Colors.neonCyan.opacity(0.7)
        case .network: RecallTheme.Colors.neonAmber
        case .error: RecallTheme.Colors.neonRed
        case .health: RecallTheme.Colors.neonMagenta
        case .location: RecallTheme.Colors.neonCyan.opacity(0.5)
        case .telemetry: RecallTheme.Colors.neonMagenta.opacity(0.7)
        }
    }
}
