import AppKit
import Foundation
import Notifications
import UserNotifications

/// Forwards a notification click to `NotificationClickHandler`; all decisions
/// live there, where `swift test` reaches them.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let handler: NotificationClickHandler

    init(handler: NotificationClickHandler) {
        self.handler = handler
    }

    /// `userInfo` is not `Sendable`, so it is decoded before the task starts.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void,
    ) {
        let payload = NotificationPayload(userInfo: response.notification.request.content.userInfo)
        let handler = handler
        Task {
            await handler.handle(payload: payload)
            completionHandler()
        }
    }

    /// Without this a notification is silently dropped while the app is frontmost.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        completionHandler([.banner])
    }

    static func openInDefaultApp(_ url: URL) async throws {
        guard await MainActor.run(body: { NSWorkspace.shared.open(url) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
    }
}

struct SystemNotificationCenter: NotificationCenterPosting {
    func isAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            return await (try? center.requestAuthorization(options: [.alert, .sound])) ?? false
        }
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    func post(_ request: NotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.body = request.body
        content.userInfo = request.payload.userInfo
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil),
        )
    }
}
