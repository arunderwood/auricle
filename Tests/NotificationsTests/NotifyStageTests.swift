import Core
import Foundation
import GRDB
@testable import Notifications
import Orchestrator
@testable import State
import Telemetry
import Testing

private struct RecordingNotifier: Notifier {
    let calls = LockedBox<[String]>([])
    func fire(meetingID _: MeetingID, title _: String, vaultPath: String) async {
        calls.value.append(vaultPath)
    }

    func fireCaptureFailed(meetingID _: MeetingID, reason _: CaptureFailureReason) async {}
}

private struct NoopNotifier: Notifier {
    func fire(meetingID _: MeetingID, title _: String, vaultPath _: String) async {}
    func fireCaptureFailed(meetingID _: MeetingID, reason _: CaptureFailureReason) async {}
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) {
        stored = value
    }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct PublishedFixture {
    let store: StateStore
    let runner: StageRunner
    let id: MeetingID
}

func makePublishedMeeting(notePath: String?, state: String = "published") async throws -> PublishedFixture {
    let store = try StateStore.forTesting(writer: DatabaseQueue())
    let id = MeetingID.generate()
    try await store.insertMeeting(Meeting(
        id: id.rawValue,
        state: state,
        createdAt: "2026-04-28T09:00:00Z",
        updatedAt: "2026-04-28T09:00:00Z",
        vaultNotePath: notePath,
    ))
    let runner = StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store))
    return PublishedFixture(store: store, runner: runner, id: id)
}

struct NotifyStageTests {
    @Test func firesAndMovesToAwaitingVerification() async throws {
        let fixture = try await makePublishedMeeting(notePath: "/v/Meetings/a.md")
        let (store, runner, id) = (fixture.store, fixture.runner, fixture.id)
        let notifier = RecordingNotifier()
        let outcome = try await NotifyStage.run(meetingID: id, title: "T", notifier: notifier, stateStore: store, stageRunner: runner)
        #expect(outcome.targetState == .awaitingVerification)
        #expect(notifier.calls.value == ["/v/Meetings/a.md"])
        let meeting = try #require(await store.fetchMeeting(id: id.rawValue))
        #expect(meeting.state == "awaiting_verification")
        #expect(meeting.verifiedAt == nil)
        let events = try await store.fetchStageEvents(meetingID: id.rawValue)
        let notifyEvents = events.filter { $0.stage == "notify" }
        #expect(notifyEvents.count == 2)
    }

    @Test func noOpNotifierStillCompletes() async throws {
        let fixture = try await makePublishedMeeting(notePath: "/v/a.md")
        let (store, runner, id) = (fixture.store, fixture.runner, fixture.id)
        _ = try await NotifyStage.run(meetingID: id, title: "T", notifier: NoopNotifier(), stateStore: store, stageRunner: runner)
        #expect(try await store.fetchMeeting(id: id.rawValue)?.state == "awaiting_verification")
    }

    @Test func missingNotePathSkipsFireAndCompletes() async throws {
        let fixture = try await makePublishedMeeting(notePath: nil)
        let (store, runner, id) = (fixture.store, fixture.runner, fixture.id)
        let notifier = RecordingNotifier()
        _ = try await NotifyStage.run(meetingID: id, title: "T", notifier: notifier, stateStore: store, stageRunner: runner)
        #expect(notifier.calls.value.isEmpty)
        #expect(try await store.fetchMeeting(id: id.rawValue)?.state == "awaiting_verification")
    }
}
