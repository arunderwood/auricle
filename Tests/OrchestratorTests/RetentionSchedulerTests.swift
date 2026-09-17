import Core
import Foundation
import GRDB
@testable import Orchestrator
@testable import State
import Testing

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

/// A 26-character, Crockford-base32-safe (no `I`/`L`/`O`/`U`) stand-in ULID.
private func meetingIDString(_ tag: String) -> String {
    let prefix = "01" + tag
    return prefix + String(repeating: "9", count: 26 - prefix.count)
}

private func makeMeeting(id: String) -> Meeting {
    Meeting(id: id, state: "verified", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
}

private func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private actor HandledTimersRecorder {
    private(set) var handledMeetingIDs: [String] = []
    func record(_ meetingID: String) {
        handledMeetingIDs.append(meetingID)
    }
}

@Test func pollOnceInvokesHandlerOnlyForDuePendingTimers() async throws {
    let store = try makeStore()
    let recorder = HandledTimersRecorder()
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)

    let due = meetingIDString("RET1")
    let notYetDue = meetingIDString("RET2")
    let alreadyFired = meetingIDString("RET3")

    try await store.insertMeeting(makeMeeting(id: due))
    try await store.insertRetentionTimer(RetentionTimer(
        meetingID: due,
        armedAt: "2026-01-01T00:00:00Z",
        firesAt: isoString(fixedNow.addingTimeInterval(-10)),
        status: "pending",
    ))

    try await store.insertMeeting(makeMeeting(id: notYetDue))
    try await store.insertRetentionTimer(RetentionTimer(
        meetingID: notYetDue,
        armedAt: "2026-01-01T00:00:00Z",
        firesAt: isoString(fixedNow.addingTimeInterval(3600)),
        status: "pending",
    ))

    try await store.insertMeeting(makeMeeting(id: alreadyFired))
    try await store.insertRetentionTimer(RetentionTimer(
        meetingID: alreadyFired,
        armedAt: "2026-01-01T00:00:00Z",
        firesAt: isoString(fixedNow.addingTimeInterval(-10)),
        status: "fired",
    ))

    let scheduler = RetentionScheduler(stateStore: store, now: { fixedNow }) { timer in
        await recorder.record(timer.meetingID)
    }

    let processed = try await scheduler.pollOnce()

    #expect(processed.map(\.meetingID) == [due])
    let handledMeetingIDs = await recorder.handledMeetingIDs
    #expect(handledMeetingIDs == [due])
}

@Test func pollOnceHandlesNothingWhenNoTimerIsDue() async throws {
    let store = try makeStore()
    let recorder = HandledTimersRecorder()
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)

    let notYetDue = meetingIDString("RET4")
    try await store.insertMeeting(makeMeeting(id: notYetDue))
    try await store.insertRetentionTimer(RetentionTimer(
        meetingID: notYetDue,
        armedAt: "2026-01-01T00:00:00Z",
        firesAt: isoString(fixedNow.addingTimeInterval(60)),
        status: "pending",
    ))

    let scheduler = RetentionScheduler(stateStore: store, now: { fixedNow }) { timer in
        await recorder.record(timer.meetingID)
    }

    let processed = try await scheduler.pollOnce()

    #expect(processed.isEmpty)
    let handledMeetingIDs = await recorder.handledMeetingIDs
    #expect(handledMeetingIDs.isEmpty)
}

@Test func pollOnceHandlesMultipleSimultaneouslyDueTimersAcrossDifferentMeetings() async throws {
    let store = try makeStore()
    let recorder = HandledTimersRecorder()
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)

    let dueA = meetingIDString("RET5")
    let dueB = meetingIDString("RET6")

    try await store.insertMeeting(makeMeeting(id: dueA))
    try await store.insertRetentionTimer(RetentionTimer(
        meetingID: dueA,
        armedAt: "2026-01-01T00:00:00Z",
        firesAt: isoString(fixedNow.addingTimeInterval(-10)),
        status: "pending",
    ))

    try await store.insertMeeting(makeMeeting(id: dueB))
    try await store.insertRetentionTimer(RetentionTimer(
        meetingID: dueB,
        armedAt: "2026-01-01T00:00:00Z",
        firesAt: isoString(fixedNow.addingTimeInterval(-5)),
        status: "pending",
    ))

    let scheduler = RetentionScheduler(stateStore: store, now: { fixedNow }) { timer in
        await recorder.record(timer.meetingID)
    }

    let processed = try await scheduler.pollOnce()

    #expect(Set(processed.map(\.meetingID)) == Set([dueA, dueB]))
    let handledMeetingIDs = await recorder.handledMeetingIDs
    #expect(Set(handledMeetingIDs) == Set([dueA, dueB]))
    #expect(handledMeetingIDs.count == 2)
}

/// `run()` loops on `interval` until its `Task` is cancelled. Seeding a
/// timer that stays `pending` forever (nothing in this scaffold marks a row
/// processed) means every poll pass re-fires the handler for it, so the
/// handler's invocation count doubles as a proxy for "how many poll passes
/// happened" — letting this test prove cancellation actually stops further
/// polling, not just that `run()` eventually returns.
@Test func runStopsPollingAfterItsTaskIsCancelled() async throws {
    let store = try makeStore()
    let recorder = HandledTimersRecorder()
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)

    let alwaysDue = meetingIDString("RET7")
    try await store.insertMeeting(makeMeeting(id: alwaysDue))
    try await store.insertRetentionTimer(RetentionTimer(
        meetingID: alwaysDue,
        armedAt: "2026-01-01T00:00:00Z",
        firesAt: isoString(fixedNow.addingTimeInterval(-10)),
        status: "pending",
    ))

    let scheduler = RetentionScheduler(stateStore: store, interval: 0.05, now: { fixedNow }) { timer in
        await recorder.record(timer.meetingID)
    }

    let runTask = Task { try? await scheduler.run() }
    // Long enough for several 0.05s poll cycles to land.
    try await Task.sleep(for: .milliseconds(180))
    runTask.cancel()
    _ = await runTask.value

    let countAfterCancel = await recorder.handledMeetingIDs.count
    #expect(countAfterCancel > 0)

    // Wait past several more would-be intervals: the count must not budge,
    // proving the loop actually stopped rather than continuing unobserved.
    try await Task.sleep(for: .milliseconds(200))
    let countAfterWaiting = await recorder.handledMeetingIDs.count
    #expect(countAfterWaiting == countAfterCancel)
}
