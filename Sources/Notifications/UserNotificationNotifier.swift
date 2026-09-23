import Core
import Foundation

/// What `UserNotificationNotifier` hands to the system notification center.
public struct NotificationRequest: Sendable {
    public let identifier: String
    public let body: String
    public let payload: NotificationPayload
}

/// The slice of `UNUserNotificationCenter` the notifier needs, so the logic
/// is testable without a running app. The real adapter lives in `App/`.
public protocol NotificationCenterPosting: Sendable {
    func isAuthorized() async -> Bool
    func post(_ request: NotificationRequest) async throws
}

/// The GUI's notifier. Permission revoked or a failed post is logged and
/// dropped: the note is already published, or the failed capture already
/// recorded.
public struct UserNotificationNotifier: Notifier {
    private let center: any NotificationCenterPosting
    private let log: Log

    public init(center: any NotificationCenterPosting, log: Log = Log(category: "notifications")) {
        self.center = center
        self.log = log
    }

    public func fire(meetingID: MeetingID, title: String, vaultPath: String) async {
        guard await center.isAuthorized() else {
            log.warn("notification permission not granted; skipping notification", ["meetingID": .publicSafe(meetingID)])
            return
        }
        let request = NotificationRequest(
            identifier: meetingID.rawValue,
            body: Self.body(title: title, vaultPath: vaultPath),
            payload: NotificationPayload(meetingID: meetingID.rawValue),
        )
        do {
            try await center.post(request)
        } catch {
            log.warn("posting the notification failed", ["meetingID": .publicSafe(meetingID)])
        }
    }

    /// Posted under `<id>-capture-failed`, so it never replaces the meeting's
    /// own published-note notification.
    public func fireCaptureFailed(meetingID: MeetingID, reason: CaptureFailureReason) async {
        guard await center.isAuthorized() else {
            log.warn("notification permission not granted; skipping capture-failed notification", ["meetingID": .publicSafe(meetingID)])
            return
        }
        let request = NotificationRequest(
            identifier: "\(meetingID.rawValue)-capture-failed",
            body: reason.message,
            payload: NotificationPayload(meetingID: meetingID.rawValue),
        )
        do {
            try await center.post(request)
        } catch {
            log.warn("posting the capture-failed notification failed", ["meetingID": .publicSafe(meetingID)])
        }
    }

    /// A note stem ending `--rerun-<YYYY-MM-DD>[-N]` marks a re-publish.
    /// `[0-9]`, not `\d`: ICU's `\d` also matches non-ASCII digits.
    static func body(title: String, vaultPath: String) -> String {
        let stem = URL(fileURLWithPath: vaultPath).deletingPathExtension().lastPathComponent
        let pattern = "--rerun-([0-9]{4}-[0-9]{2}-[0-9]{2})(-[0-9]+)?$"
        guard
            let match = stem.range(of: pattern, options: .regularExpression),
            let date = stem[match].range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression)
        else {
            return "auricle: meeting ready — \(title)"
        }
        return "auricle: re-published \(title) (rerun \(stem[match][date]))"
    }
}
