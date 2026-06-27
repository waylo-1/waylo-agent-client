import SwiftUI

/// An animated pulsing red dot drawn over the element the user must click.
struct DotView: View {
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Outer pulse ring.
            Circle()
                .fill(Color.red.opacity(0.3))
                .frame(width: 44, height: 44)
                .scaleEffect(isPulsing ? 1.4 : 1.0)
                .opacity(isPulsing ? 0.0 : 0.6)
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: false),
                    value: isPulsing
                )

            // Inner solid dot.
            Circle()
                .fill(Color.red)
                .frame(width: 22, height: 22)
                .shadow(color: .red.opacity(0.5), radius: 6)
        }
        .frame(width: 44, height: 44)
        .onAppear { isPulsing = true }
    }
}

#Preview {
    DotView()
        .frame(width: 100, height: 100)
        .background(Color.white)
}

/// The red dot with an instruction caption shown just below it.
struct DotWithCaption: View {
    let caption: String

    var body: some View {
        VStack(spacing: 8) {
            DotView()
                .frame(width: 44, height: 44)

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.black.opacity(0.78))
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260)
            }
        }
        .frame(width: 280, alignment: .center)
    }
}

#Preview {
    DotWithCaption(caption: "Click the Bold button in the toolbar.")
        .frame(width: 300, height: 140)
        .background(Color.gray)
}

/// A centered instruction banner for non-click steps (type / press a key).
struct BannerView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundColor(.white)
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
        )
        .frame(maxWidth: 440)
    }
}

/// A spinner shown in place of the dot while a vision fallback is running.
struct LoadingDotView: View {
    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.35))
                .frame(width: 44, height: 44)

            Circle()
                .trim(from: 0.0, to: 0.7)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(rotation))
                .animation(
                    .linear(duration: 0.8).repeatForever(autoreverses: false),
                    value: rotation
                )
        }
        .frame(width: 44, height: 44)
        .onAppear { rotation = 360 }
    }
}

#Preview {
    LoadingDotView()
        .frame(width: 100, height: 100)
        .background(Color.gray)
}
