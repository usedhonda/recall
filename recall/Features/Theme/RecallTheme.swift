import SwiftUI

// MARK: - RecallTheme

enum RecallTheme {

    // MARK: - Colors

    enum Colors {
        static let bg = Color(hex: 0x000000)
        static let surface = Color(hex: 0x0A0A0F)
        static let surfaceAlt = Color(hex: 0x12121A)
        static let border = Color(hex: 0x1A1A2E)
        static let neonCyan = Color(hex: 0x00F0FF)
        static let neonGreen = Color(hex: 0x00FF88)
        static let neonMagenta = Color(hex: 0xFF00AA)
        static let neonAmber = Color(hex: 0xFFAA00)
        static let neonRed = Color(hex: 0xFF2244)
        static let textPrimary = Color(hex: 0xE0E0E0)
        static let textSecondary = Color(hex: 0x666680)
        static let textMuted = Color(hex: 0x333344)
    }

    // MARK: - Fonts

    enum Fonts {
        static let hudTitle = Font.system(size: 14, weight: .semibold, design: .monospaced)
        static let hudBody = Font.system(size: 13, weight: .regular, design: .monospaced)
        static let hudCaption = Font.system(size: 11, weight: .regular, design: .monospaced)
        static let hudMicro = Font.system(size: 9, weight: .medium, design: .monospaced)
        static let hudLarge = Font.system(size: 28, weight: .bold, design: .monospaced)
        static let hudMeter = Font.system(size: 15, weight: .medium, design: .monospaced)
    }
}

// MARK: - Color(hex:) Extension

extension Color {
    init(hex: UInt) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - HUD Card Modifier

struct HUDCardModifier: ViewModifier {
    var borderColor: Color = RecallTheme.Colors.border

    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(RecallTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(borderColor, lineWidth: 1)
            )
    }
}

extension View {
    func hudCard(borderColor: Color = RecallTheme.Colors.border) -> some View {
        modifier(HUDCardModifier(borderColor: borderColor))
    }
}

// MARK: - HUD Section Header

struct HUDSectionHeader: View {
    let title: String
    var color: Color = RecallTheme.Colors.neonCyan

    var body: some View {
        Text(title.uppercased())
            .font(RecallTheme.Fonts.hudTitle)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - HUD Meter Bar

struct HUDMeterBar: View {
    let label: String
    let value: Float
    let threshold: Float
    var barColor: Color = RecallTheme.Colors.neonCyan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(RecallTheme.Fonts.hudCaption)
                    .foregroundStyle(RecallTheme.Colors.textSecondary)
                Spacer()
                Text(String(format: "%.3f", value))
                    .font(RecallTheme.Fonts.hudMeter)
                    .foregroundStyle(value > threshold ? barColor : RecallTheme.Colors.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(RecallTheme.Colors.surfaceAlt)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(
                            LinearGradient(
                                colors: [barColor.opacity(0.6), barColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(0, geo.size.width * CGFloat(min(value, 1.0))))

                    Rectangle()
                        .fill(RecallTheme.Colors.neonAmber)
                        .frame(width: 2, height: geo.size.height + 4)
                        .offset(x: geo.size.width * CGFloat(min(threshold, 1.0)) - 1)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Cyberpunk Stream Toggle

struct CyberpunkStreamToggle: View {
    let icon: String
    let label: String
    let isActive: Bool
    let neonColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label.uppercased())
                    .font(RecallTheme.Fonts.hudMicro)
                Text(isActive ? "ON" : "OFF")
                    .font(RecallTheme.Fonts.hudMicro)
                    .fontWeight(.bold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isActive ? neonColor.opacity(0.12) : RecallTheme.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isActive ? neonColor : RecallTheme.Colors.border, lineWidth: 1)
            )
            .foregroundStyle(isActive ? neonColor : RecallTheme.Colors.textMuted)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - HUD Header Bar

struct HUDHeaderBar: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(RecallTheme.Fonts.hudTitle)
                .foregroundStyle(RecallTheme.Colors.neonCyan)
                .tracking(4)
            Spacer()
            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - HUD Action Button

struct HUDActionButton: View {
    let title: String
    let icon: String
    var color: Color = RecallTheme.Colors.neonCyan
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title.uppercased(), systemImage: icon)
                .font(RecallTheme.Fonts.hudBody)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(color.opacity(0.5), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
