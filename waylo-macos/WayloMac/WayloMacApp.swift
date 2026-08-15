import SwiftUI

@main
struct WayloMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No WindowGroup — windows are managed manually via AppDelegate.
        Settings { EmptyView() }
    }
}
