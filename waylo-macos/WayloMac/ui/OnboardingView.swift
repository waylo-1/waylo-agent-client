import SwiftUI

/// Guides the user to grant Accessibility permission.
struct OnboardingView: View {
    /// Called when the user confirms permission has been granted.
    var onGranted: (() -> Void)?

    @State private var stillNeedsPermission = false

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 48))
                .foregroundColor(.red)

            Text("Welcome to Waylo")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Waylo needs one permission to guide you through any app on your Mac.")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                PermissionStep(number: "1", text: "Open System Settings")
                PermissionStep(number: "2", text: "Go to Privacy & Security → Accessibility")
                PermissionStep(number: "3", text: "Toggle ON next to Waylo")
            }
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)

            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button("I've granted permission →") {
                if AXIsProcessTrusted() {
                    onGranted?()
                } else {
                    stillNeedsPermission = true
                }
            }
            .buttonStyle(.bordered)

            if stillNeedsPermission {
                Text("Permission not detected yet. Toggle Waylo ON in Accessibility, then try again.")
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(width: 440)
    }
}

struct PermissionStep: View {
    let number: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(number)
                .font(.caption)
                .fontWeight(.bold)
                .frame(width: 24, height: 24)
                .background(Color.red)
                .foregroundColor(.white)
                .clipShape(Circle())
            Text(text).font(.body)
        }
    }
}

#Preview {
    OnboardingView()
}
