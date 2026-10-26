import SwiftUI

struct HubConnectionBanner: View {
    let issue: HubConnectionIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(issue.title, systemImage: "exclamationmark.triangle.fill")
                .font(RecallTheme.Fonts.hudCaption)
            Text(issue.detail)
                .font(RecallTheme.Fonts.hudBody)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(RecallTheme.Colors.neonRed)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(RecallTheme.Colors.neonRed.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(RecallTheme.Colors.neonRed.opacity(0.3), lineWidth: 1))
        .padding(.horizontal, 12)
    }
}
