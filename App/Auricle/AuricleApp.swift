import Core
import Notifications
import Permissions
import State
import SwiftUI
import UserNotifications

/// Notification authorization is requested at runtime via UNUserNotificationCenter
/// and gated by NSUserNotificationsUsageDescription in Info.plist — macOS has no
/// entitlement key for it, so none appears in Auricle.entitlements.
@main
struct AuricleApp: App {
    /// Shared for the process so its per-category memo (AR-PAT-4) reflects
    /// every caller's checks, not just the notification path's own.
    private static let permissionChecker = PermissionChecker()
    private static let notificationDelegate = makeNotificationDelegate()

    init() {
        UNUserNotificationCenter.current().delegate = Self.notificationDelegate
    }

    var body: some Scene {
        WindowGroup {
            Text("auricle")
        }
    }

    /// The GUI's `Notifier` is a `UserNotificationNotifier`; the pipeline that
    /// fires it is not wired into the GUI yet, so only the click side is live.
    /// Without a configured vault there is no note to open, so no delegate.
    static func makeNotifier() -> any Notifier {
        let authorization = PermissionCheckedNotificationAuthorization(permissionChecker: permissionChecker)
        return UserNotificationNotifier(center: SystemNotificationCenter(authorization: authorization))
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
