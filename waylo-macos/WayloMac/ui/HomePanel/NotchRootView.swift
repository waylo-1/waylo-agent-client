import SwiftUI

/// Dynamic-Island style notch content. Collapsed it hugs the notch (an activity
/// indicator while a guide runs); hover or click expands the full panel.
struct NotchRootView: View {
    @ObservedObject var expansion: NotchExpansion
    @ObservedObject private var engine = GuidanceEngine.shared

    var body: some View {
        ZStack(alignment: .top) {
            if expansion.expanded {
                expandedPanel
            } else if engine.isRunning {
                // Display-only: the pill window is click-through so it can
                // never block menu items beneath it. Open via menu-bar icon
                // or ⌃⌥⌘W.
                runningIndicator
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .preferredColorScheme(.dark)
    }

    // MARK: - Running: compact indicator that looks like the notch widened

    private var runningIndicator: some View {
        HStack(spacing: 0) {
            // Left of notch: step counter.
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("\(engine.currentStepIndex + 1)/\(engine.stepCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)

            // The notch gap (kept clear so the real notch shows through).
            Spacer().frame(width: NotchMetrics.current().width)

            // Right of notch: equalizer.
            EqualizerView(active: engine.state == .locating || engine.state == .showing)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(NotchMetrics.current().height, 28))
        .background(BottomRoundedRectangle(radius: 11).fill(Color.black))
    }

    // MARK: - Expanded full panel

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    expansion.expanded = false
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.6))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            HomePanelView()
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .background(BottomRoundedRectangle(radius: 18).fill(Color.black.opacity(0.95)))
        .overlay(BottomRoundedRectangle(radius: 18).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// A small animated audio-style equalizer.
struct EqualizerView: View {
    var active: Bool
    @State private var phase = false
    private let bars = 4

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 3, height: barHeight(i))
                    .animation(
                        active
                        ? .easeInOut(duration: 0.4 + Double(i) * 0.08).repeatForever(autoreverses: true)
                        : .default,
                        value: phase
                    )
            }
        }
        .frame(height: 18)
        .onAppear { phase = true }
    }

    private func barHeight(_ i: Int) -> CGFloat {
        guard active else { return 5 }
        let highs: [CGFloat] = [14, 18, 10, 16]
        return phase ? highs[i % highs.count] : 5
    }
}

/// Rectangle with only its bottom corners rounded — flush at the top so it
/// blends into the notch.
struct BottomRoundedRectangle: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        p.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
            radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        p.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        p.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
            radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        p.closeSubpath()
        return p
    }
}
