import SwiftUI

struct ActivityLogView: View {
    let entries: [ActivityLogger.Entry]
    var maxVisible: Int = 50

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let visible = entries.suffix(maxVisible)
                    ForEach(visible) { entry in
                        Text(entry.formatted)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(color(for: entry.category))
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
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
        case .state: .primary
        case .vad: .cyan
        case .chunk: .green
        case .upload: .blue
        case .network: .orange
        case .error: .red
        }
    }
}
