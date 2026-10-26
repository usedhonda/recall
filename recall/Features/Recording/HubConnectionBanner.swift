import SwiftUI

struct HubConnectionBanner: View {
    let issue: HubConnectionIssue
    private var color: Color { issue.isRetrying ? RecallTheme.Colors.neonAmber : RecallTheme.Colors.neonRed }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(RecallTheme.Fonts.hudCaption)
            Text(issue.detail)
                .font(RecallTheme.Fonts.hudBody)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 12)
    }
}
