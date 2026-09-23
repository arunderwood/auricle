import Core
import Foundation
@testable import Notifications
import os
import Testing

private final class FakeCenter: NotificationCenterPosting {
    let authorized: Bool
    let fails: Bool
    let posted = OSAllocatedUnfairLock<[NotificationRequest]>(initialState: [])

    init(authorized: Bool = true, fails: Bool = false) {
        self.authorized = authorized
        self.fails = fails
    }

    func isAuthorized() async -> Bool {
        authorized
    }

    func post(_ request: NotificationRequest) async throws {
        if fails {
            throw CocoaError(.fileWriteUnknown)
        }
        posted.withLock { $0.append(request) }
    }
}

struct UserNotificationNotifierTests {
    let id = MeetingID.generate()

    @Test func freshBodyAndPayload() async {
        let center = FakeCenter()
        await UserNotificationNotifier(center: center)
            .fire(meetingID: id, title: "Tuesday sync with Ben", vaultPath: "/v/Meetings/x.md")
        let request = center.posted.withLock { $0 }.first
        #expect(request?.body == "auricle: meeting ready — Tuesday sync with Ben")
        #expect(request?.payload == NotificationPayload(meetingID: id.rawValue))
    }

    @Test(arguments: [
        "/v/Meetings/x--rerun-2026-05-15.md",
        "/v/Meetings/x--rerun-2026-05-15-2.md",
    ])
    func rerunBody(path: String) async {
        let center = FakeCenter()
        await UserNotificationNotifier(center: center).fire(meetingID: id, title: "T", vaultPath: path)
        #expect(center.posted.withLock { $0 }.first?.body == "auricle: re-published T (rerun 2026-05-15)")
    }

    @Test func nonRerunSuffixIsFresh() {
        #expect(UserNotificationNotifier.body(title: "T", vaultPath: "/v/x--rerun-notadate.md") == "auricle: meeting ready — T")
    }

    @Test func deniedPermissionLogsAndPostsNothing() async {
        let center = FakeCenter(authorized: false)
        let recorder = LogRecorder()
        await UserNotificationNotifier(center: center, log: recorder.log).fire(meetingID: id, title: "T", vaultPath: "/v/x.md")
        #expect(center.posted.withLock { $0 }.isEmpty)
        #expect(recorder.records.count == 1)
    }

    @Test func postFailureIsSwallowed() async {
        let recorder = LogRecorder()
        await UserNotificationNotifier(center: FakeCenter(fails: true), log: recorder.log).fire(meetingID: id, title: "T", vaultPath: "/v/x.md")
        #expect(recorder.records.count == 1)
    }

    @Test func captureFailedPostsUnderItsOwnIdentifier() async {
        let center = FakeCenter()
        await UserNotificationNotifier(center: center).fireCaptureFailed(meetingID: id, reason: .permissionRevokedMidstream)
        let request = center.posted.withLock { $0 }.first
        #expect(request?.identifier == "\(id.rawValue)-capture-failed")
        #expect(request?.body == "Recording stopped — a permission was revoked. The partial audio is saved.")
        #expect(request?.payload == NotificationPayload(meetingID: id.rawValue))
    }

    @Test func captureFailedWithNotificationsDeniedWarnsAndPostsNothing() async {
        let center = FakeCenter(authorized: false)
        let recorder = LogRecorder()
        await UserNotificationNotifier(center: center, log: recorder.log).fireCaptureFailed(meetingID: id, reason: .permissionRevokedMidstream)
        #expect(center.posted.withLock { $0 }.isEmpty)
        #expect(recorder.records.map(\.level) == [.default])
    }
}
