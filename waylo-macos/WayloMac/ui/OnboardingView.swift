import SwiftUI
import Speech
import AVFoundation

/// First-run setup: all three permissions with LIVE status, so the user never
/// discovers a missing grant mid-task. Accessibility is mandatory (guides
/// can't run without it); Screen Recording and Microphone are strongly
/// recommended and shown honestly as such.
struct OnboardingView: View {
    /// Called when the user finishes (Accessibility granted).
    var onGranted: (() -> Void)?

    @State private var axGranted = AXIsProcessTrusted()
    @State private var screenGranted = ScreenRecordingPermission.isGranted
    @State private var micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        && SFSpeechRecognizer.authorizationStatus() == .authorized

    private let refresh = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 44))
                .foregroundColor(.red)

            Text("Welcome to Waylo")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Waylo guides you through any app with a talking pointer. It needs a few permissions to see and speak.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(spacing: 10) {
                PermissionRow(
                    granted: axGranted,
                    title: "Accessibility",
                    detail: "Required — reads the app's buttons and menus to point at them",
                    buttonTitle: "Open Settings"
                ) {
                    openPane("Privacy_Accessibility")
                }
                PermissionRow(
                    granted: screenGranted,
                    title: "Screen Recording",
                    detail: "Finds elements visually when the app doesn't describe them",
                    buttonTitle: "Grant"
                ) {
                    if !ScreenRecordingPermission.request() {
                        ScreenRecordingPermission.openSettings()
                    }
                }
                PermissionRow(
                    granted: micGranted,
                    title: "Microphone & Speech",
                    detail: "Lets you speak tasks and questions instead of typing",
                    buttonTitle: "Grant"
                ) {
                    MicHandler.shared.requestPermission()
                    // If the system prompts were already used up, send them to
                    // Settings after a beat.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if !micGranted { openPane("Privacy_Microphone") }
                    }
                }
            }
            .padding(14)
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)

            Button(axGranted ? "Start using Waylo →" : "Grant Accessibility to continue") {
                if axGranted { onGranted?() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!axGranted)

            if !axGranted {
                Text("After toggling Waylo ON in System Settings → Privacy & Security → Accessibility, this screen updates by itself.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            } else if !screenGranted || !micGranted {
                Text("You can start now — the remaining permissions just unlock vision fallback and voice.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(width: 460)
        .onReceive(refresh) { _ in
            axGranted = AXIsProcessTrusted()
            screenGranted = ScreenRecordingPermission.isGranted
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                && SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    private func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One permission line: live status dot, name + why, and an action button
/// that disappears once granted.
struct PermissionRow: View {
    let granted: Bool
    let title: String
    let detail: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundColor(granted ? .green : .secondary)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).fontWeight(.medium)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if !granted {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}

#Preview {
    OnboardingView()
}
