import SwiftUI

// MARK: - GlitchText

struct GlitchText: View {
    let text: String
    let font: Font
    let color: Color
    var tracking: CGFloat = 0
    var continuousGlitch: Bool = false

    @State private var redOffset: CGFloat = 0
    @State private var blueOffset: CGFloat = 0
    @State private var microTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Text(text)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(Color.red.opacity(0.7))
                .offset(x: redOffset, y: -redOffset * 0.3)
                .blendMode(.screen)

            Text(text)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(Color.blue.opacity(0.7))
                .offset(x: -blueOffset, y: blueOffset * 0.3)
                .blendMode(.screen)

            Text(text)
                .font(font)
                .tracking(tracking)
                .foregroundStyle(color)
        }
        .onChange(of: text) {
            burstGlitch()
        }
        .onChange(of: continuousGlitch) { _, active in
            if active {
                startMicroGlitch()
            } else {
                stopMicroGlitch()
            }
        }
        .onAppear {
            if continuousGlitch { startMicroGlitch() }
        }
        .onDisappear { stopMicroGlitch() }
    }

    private func burstGlitch() {
        Task { @MainActor in
            for i in 0..<7 {
                let factor = CGFloat(7 - i) / 7.0
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    redOffset = .random(in: -4...4) * factor
                    blueOffset = .random(in: -4...4) * factor
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            withAnimation(.easeOut(duration: 0.15)) {
                redOffset = 0
                blueOffset = 0
            }
        }
    }

    private func startMicroGlitch() {
        stopMicroGlitch()
        microTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(.random(in: 3...5)))
                guard !Task.isCancelled else { return }
                var t = Transaction()
                t.disablesAnimations = true
                withTransaction(t) {
                    redOffset = .random(in: -2...2)
                    blueOffset = .random(in: -2...2)
                }
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    redOffset = 0
                    blueOffset = 0
                }
            }
        }
    }

    private func stopMicroGlitch() {
        microTask?.cancel()
        microTask = nil
    }
}

// MARK: - NeonGlow

struct NeonGlow: ViewModifier {
    let color: Color
    var radius: CGFloat = 16
    @State private var glowing = false

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(glowing ? 0.8 : 0.4), radius: radius / 2)
            .shadow(color: color.opacity(glowing ? 0.6 : 0.2), radius: radius)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    glowing = true
                }
            }
    }
}

extension View {
    func neonGlow(color: Color, radius: CGFloat = 16) -> some View {
        modifier(NeonGlow(color: color, radius: radius))
    }
}

// MARK: - ScanlineOverlay

struct ScanlineOverlay: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 3
            var y: CGFloat = 0
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(rect), with: .color(.white.opacity(0.03)))
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - PulsingDot

struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 8
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .scaleEffect(pulsing ? 1.4 : 1.0)
            .opacity(pulsing ? 0.5 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            }
    }
}

// MARK: - VignetteOverlay

struct VignetteOverlay: View {
    var body: some View {
        RadialGradient(
            colors: [.clear, Color.black.opacity(0.25)],
            center: .center,
            startRadius: 250,
            endRadius: 550
        )
        .allowsHitTesting(false)
    }
}

// MARK: - HUD Corner Bracket

struct HUDCornerBrackets: ViewModifier {
    var color: Color = RecallTheme.Colors.border
    var length: CGFloat = 12
    var lineWidth: CGFloat = 1

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                Canvas { ctx, _ in
                    var path = Path()
                    // Top-left
                    path.move(to: CGPoint(x: 0, y: length))
                    path.addLine(to: .zero)
                    path.addLine(to: CGPoint(x: length, y: 0))
                    // Top-right
                    path.move(to: CGPoint(x: w - length, y: 0))
                    path.addLine(to: CGPoint(x: w, y: 0))
                    path.addLine(to: CGPoint(x: w, y: length))
                    // Bottom-right
                    path.move(to: CGPoint(x: w, y: h - length))
                    path.addLine(to: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: w - length, y: h))
                    // Bottom-left
                    path.move(to: CGPoint(x: length, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: 0, y: h - length))
                    ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
                }
            }
            .allowsHitTesting(false)
        )
    }
}

extension View {
    func hudBrackets(color: Color = RecallTheme.Colors.border) -> some View {
        modifier(HUDCornerBrackets(color: color))
    }
}

// MARK: - Neon Divider

struct NeonDivider: View {
    var color: Color = RecallTheme.Colors.border
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, color.opacity(0.6), color, color.opacity(0.6), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}
