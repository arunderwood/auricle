import Foundation
@testable import Notifications
import Testing

struct NotificationClickHandlerTests {
    let vault = URL(fileURLWithPath: "/v")

    @Test func knownPayloadOpensURLOnceAndLeavesStateAlone() async throws {
        let fixture = try await makePublishedMeeting(notePath: "/v/Meetings/a b.md", state: "awaiting_verification")
        let (store, id) = (fixture.store, fixture.id)
        let opened = LockedBox<[URL]>([])
        let handler = NotificationClickHandler(vaultRoot: vault, stateStore: store) { opened.value.append($0) }
        await handler.handle(userInfo: NotificationPayload(meetingID: id.rawValue).userInfo)
        #expect(opened.value.map(\.absoluteString) == ["obsidian://open?vault=v&file=Meetings/a%20b"])
        #expect(try await store.fetchMeeting(id: id.rawValue)?.state == "awaiting_verification")
    }

    @Test func futurePayloadVersionDoesNotOpen() async throws {
        let fixture = try await makePublishedMeeting(notePath: "/v/a.md")
        let (store, id) = (fixture.store, fixture.id)
        let opened = LockedBox<[URL]>([])
        let recorder = LogRecorder()
        let handler = NotificationClickHandler(vaultRoot: vault, stateStore: store, opener: { opened.value.append($0) }, log: recorder.log)
        await handler.handle(userInfo: NotificationPayload(meetingID: id.rawValue, payloadVersion: 2).userInfo)
        #expect(opened.value.isEmpty)
        #expect(recorder.records.count == 1)
    }

    @Test func noNotePathDoesNotOpen() async throws {
        let fixture = try await makePublishedMeeting(notePath: nil)
        let (store, id) = (fixture.store, fixture.id)
        let opened = LockedBox<[URL]>([])
        let recorder = LogRecorder()
        let handler = NotificationClickHandler(vaultRoot: vault, stateStore: store, opener: { opened.value.append($0) }, log: recorder.log)
        await handler.handle(userInfo: NotificationPayload(meetingID: id.rawValue).userInfo)
        #expect(opened.value.isEmpty)
        #expect(recorder.records.count == 1)
    }

    @Test func unknownMeetingAndGarbageUserInfoDoNotOpen() async throws {
        let fixture = try await makePublishedMeeting(notePath: "/v/a.md")
        let (store, id) = (fixture.store, fixture.id)
        let opened = LockedBox<[URL]>([])
        let handler = NotificationClickHandler(vaultRoot: vault, stateStore: store) { opened.value.append($0) }
        await handler.handle(userInfo: NotificationPayload(meetingID: "nope").userInfo)
        await handler.handle(userInfo: ["x": 1])
        #expect(opened.value.isEmpty)
    }

    @Test func openerFailureIsIgnored() async throws {
        let fixture = try await makePublishedMeeting(notePath: "/v/a.md")
        let (store, id) = (fixture.store, fixture.id)
        let recorder = LogRecorder()
        let handler = NotificationClickHandler(vaultRoot: vault, stateStore: store, opener: { _ in throw CocoaError(.fileNoSuchFile) }, log: recorder.log)
        await handler.handle(userInfo: NotificationPayload(meetingID: id.rawValue).userInfo)
        #expect(recorder.records.count == 1)
    }
}
