import AppUI
import Core
import Notifications
import State
import SwiftUI
import UserNotifications

/// Notification authorization is requested at runtime via UNUserNotificationCenter
/// and gated by NSUserNotificationsUsageDescription in Info.plist — macOS has no
/// entitlement key for it, so none appears in Auricle.entitlements.
@main
struct AuricleApp: App {
    private static let notificationDelegate = makeNotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            AuricleRootView()
        }
    }

    /// The GUI's `Notifier` is a `UserNotificationNotifier`; the pipeline that
    /// fires it is not wired into the GUI yet, so only the click side is live.
    /// Without a configured vault there is no note to open, so no delegate.
    static func makeNotifier() -> any Notifier {
        UserNotificationNotifier(center: SystemNotificationCenter())
    }

    private static func makeNotificationDelegate() -> NotificationDelegate? {
        let log = Log(category: "app")
        guard
            let config = try? Config.load(),
            let vaultRoot = config.vaultPath,
            let store = try? StateStore.production()
        else {
            log.warn("notification click handling disabled: no vault path or state store")
            return nil
        }
        return NotificationDelegate(handler: NotificationClickHandler(
            vaultRoot: vaultRoot,
            stateStore: store,
            opener: NotificationDelegate.openInDefaultApp,
        ))
    }
}

/// `isRecording` is local view state; no capture source drives it.
private struct AuricleRootView: View {
    @State private var isRecording = false

    var body: some View {
        Text("auricle")
            .toolbar {
                ToolbarItem {
                    RecordingIndicator(isRecording: isRecording)
                }
            }
    }
}
