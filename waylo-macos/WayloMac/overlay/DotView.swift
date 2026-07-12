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

/// An up/down arrow shown at the scroll bar when the target is off-screen,
/// prompting the user to scroll. Bounces in the scroll direction.
struct ScrollArrowView: View {
    let down: Bool
    let caption: String
    @State private var bounce = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.92))
                    .frame(width: 46, height: 46)
                    .shadow(color: .red.opacity(0.5), radius: 8)
                Image(systemName: down ? "chevron.down" : "chevron.up")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white)
            }
            .offset(y: bounce ? (down ? 9 : -9) : 0)
            .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: bounce)

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.82)))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 220)
            }
        }
        .frame(width: 240, height: 130, alignment: .top)
        .onAppear { bounce = true }
    }
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
        // Pin to the TOP of the host frame so the dot's center sits exactly
        // 22pt below the frame's top edge — OverlayWindowController.present()
        // relies on this fixed anchor. Without an explicit height + .top
        // alignment SwiftUI centers the VStack vertically, shifting the dot down.
        .frame(width: 280, height: 120, alignment: .top)
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

/// A dotted "click anywhere in here" region drawn around the target element's
/// actual bounds, with the instruction below. Marching-ants dashes make it
/// read as a live region, not a static decoration.
struct HighlightBoxView: View {
    let boxSize: CGSize
    let caption: String
    @State private var dashPhase: CGFloat = 0
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color.red, style: StrokeStyle(lineWidth: 2.5, dash: [7, 5], dashPhase: dashPhase))
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.red.opacity(pulse ? 0.10 : 0.04))
                )
                .frame(width: boxSize.width, height: boxSize.height)
                .shadow(color: .red.opacity(0.5), radius: 6)
                .onAppear {
                    withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                        dashPhase = -12
                    }
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }

            if !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.78)))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 300)
            }
        }
    }
}

/// A numbered badge marking one of several candidate matches when detection
/// is ambiguous ("Empty" in three places). The user clicks the right one.
struct CandidateBadgeView: View {
    let number: Int
    let isPrimary: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isPrimary ? Color.red : Color.orange)
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.45), radius: 5)
                .scaleEffect(pulse ? 1.12 : 1.0)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text("\(number)")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 56, height: 56)
        .onAppear { pulse = true }
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
