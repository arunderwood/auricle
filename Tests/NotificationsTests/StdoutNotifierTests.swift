import Core
import Foundation
@testable import Notifications
import os
import Testing

struct StdoutNotifierTests {
    @Test func printsPathThenURL() async {
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        let notifier = StdoutNotifier(vaultRoot: URL(fileURLWithPath: "/v")) { line in
            lines.withLock { $0.append(line) }
        }
        await notifier.fire(meetingID: .generate(), title: "t", vaultPath: "/v/Meetings/a b.md")
        #expect(lines.withLock { $0 } == ["/v/Meetings/a b.md", "obsidian://open?vault=v&file=Meetings/a%20b"])
    }

    @Test func captureFailedPrintsOneLine() async {
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        let notifier = StdoutNotifier(vaultRoot: URL(fileURLWithPath: "/v")) { line in
            lines.withLock { $0.append(line) }
        }
        let id = MeetingID.generate()
        await notifier.fireCaptureFailed(meetingID: id, reason: .permissionRevokedMidstream)
        #expect(lines.withLock { $0 } == ["\(id.rawValue): Recording stopped — a permission was revoked. The partial audio is saved."])
    }
}
