import SwiftUI

/// Live debug state shown in the on-screen overlay panel.
@MainActor
final class DebugState: ObservableObject {
    static let shared = DebugState()

    @Published var targetApp = "-"
    @Published var layerResolved = "-"
    @Published var dotPosition = "-"
    @Published var screenInfo = "-"
    @Published var cacheStatus = "-"
    @Published var yoloResult = "—"
    @Published var yoloElementCount = 0

    private init() {}

    func update(targetApp: String? = nil, layer: String? = nil, dot: CGPoint? = nil, screen: CGRect? = nil, cache: String? = nil) {
        if let targetApp { self.targetApp = targetApp }
        if let layer { self.layerResolved = layer }
        if let dot { self.dotPosition = String(format: "x=%.0f y=%.0f", dot.x, dot.y) }
        if let screen { self.screenInfo = String(format: "%.0fx%.0f", screen.width, screen.height) }
        if let cache { self.cacheStatus = cache }
    }
}

/// Small semi-transparent diagnostic panel (top-right).
struct DebugOverlayView: View {
    @ObservedObject var state = DebugState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SAHAYAK DEBUG")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
            row("Target app", state.targetApp)
            row("Layer", state.layerResolved)
            row("Dot", state.dotPosition)
            row("Screen", state.screenInfo)
            row("Cache", state.cacheStatus)
            row("L2.5", "\(state.yoloResult) (\(state.yoloElementCount))")
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundColor(.white)
        .padding(10)
        .frame(width: 280, height: 208, alignment: .topLeading)
        .background(Color.black.opacity(0.82))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":").foregroundColor(.gray)
            Text(value).foregroundColor(.white).lineLimit(2)
        }
    }
}
