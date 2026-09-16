import SwiftUI

// Notification authorization is requested at runtime via UNUserNotificationCenter
// and gated by NSUserNotificationsUsageDescription in Info.plist — macOS has no
// entitlement key for it, so none appears in Auricle.entitlements.
@main
struct AuricleApp: App {
    var body: some Scene {
        WindowGroup {
            Text("auricle")
        }
    }
}
