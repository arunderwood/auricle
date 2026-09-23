@testable import Core
import Foundation
import GRDB
@testable import Orchestrator
import os
@testable import State
@testable import Telemetry
import Testing

/// A 26-character, Crockford-base32-safe (no `I`/`L`/`O`/`U`) stand-in ULID:
/// `MeetingID(ulid:)` validates its shape, and the sweep skips any row that
/// fails that validation, so fixtures must actually pass it.
private func meetingID(_ tag: String) -> String {
    let prefix = "01" + tag
    return prefix + String(repeating: "9", count: 26 - prefix.count)
}

private func makeMeeting(id: String, state: String, updatedAt: String = "2026-01-01T00:00:00Z") -> Meeting {
    Meeting(id: id, state: state, createdAt: "2026-01-01T00:00:00Z", updatedAt: updatedAt)
}

private func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

private func makeRunner(
    store: StateStore,
    now: @escaping @Sendable () -> Date = { Date() },
    log: Log = Log(category: "orchestrator"),
) -> StageRunner {
    StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store), now: now, log: log)
}

/// Hands out `dates` one per call, then repeats the last, and counts the calls.
private final class SteppingClock: Sendable {
    private let dates: [Date]
    private let calls = OSAllocatedUnfairLock<Int>(initialState: 0)

    init(_ dates: [Date]) {
        self.dates = dates
    }

    var callCount: Int {
        calls.withLock { $0 }
    }

    func now() -> Date {
        calls.withLock { count in
            defer { count += 1 }
            return dates[min(count, dates.count - 1)]
        }
    }
}

private actor InvocationCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

// MARK: - `run`: the transition table

@Test func runRefusesAStageAndStatePairWithNoTableEntryBeforeWritingAnything() async throws {
    let store = try makeStore()
    let id = meetingID("TB01")
    try await store.insertMeeting(makeMeeting(id: id, state: "recording"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))
    let workRuns = InvocationCounter()

    await #expect(throws: StageRunner.TransitionError.unsupportedStage(stage: .capture, activeState: .recording)) {
        try await runner.run(stage: .capture, meetingID: resolvedID, activeState: .recording) {
            await workRuns.increment()
            return .completed(targetState: .captured)
        }
    }

    #expect(await workRuns.count == 0)
    #expect(try await store.fetchStageEvents(meetingID: id).isEmpty)
    #expect(try await store.fetchMeeting(id: id)?.state == "recording")
}

@Test func runRefusesAnOutcomeTargetingAStateOutsideItsEntryAndWritesNoTxnB() async throws {
    let store = try makeStore()
    let id = meetingID("TB02")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    await #expect(throws: StageRunner.TransitionError.targetNotAllowed(stage: .transcribe, activeState: .transcribing, targetState: .published)) {
        try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
            .completed(targetState: .published)
        }
    }
    await #expect(throws: StageRunner.TransitionError.targetNotAllowed(stage: .transcribe, activeState: .transcribing, targetState: .summarizationFailed)) {
        try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
            .failed(targetState: .summarizationFailed, errorClass: "wrong_stage")
        }
    }

    // Txn A of each attempt landed, and no Txn B did: the meeting is left as a
    // crashed stage would leave it.
    #expect(try await store.fetchStageEvents(meetingID: id).map(\.event) == ["started", "started"])
    #expect(try await store.fetchMeeting(id: id)?.state == "transcribing")
}

@Test func aRejectedTransitionIsLoggedAtErrorWithTheStageAndBothStates() async throws {
    let store = try makeStore()
    let unsupported = meetingID("TB04")
    let wrongTarget = meetingID("TB05")
    try await store.insertMeeting(makeMeeting(id: unsupported, state: "recording"))
    try await store.insertMeeting(makeMeeting(id: wrongTarget, state: "captured"))
    let recorder = LogRecorder()
    let runner = makeRunner(store: store, log: recorder.log)

    _ = try? await runner.run(stage: .capture, meetingID: #require(MeetingID(ulid: unsupported)), activeState: .recording) {
        .completed(targetState: .captured)
    }
    let afterUnsupported = recorder.records
    _ = try? await runner.run(stage: .transcribe, meetingID: #require(MeetingID(ulid: wrongTarget)), activeState: .transcribing) {
        .completed(targetState: .published)
    }

    #expect(afterUnsupported.map(\.level) == [.error])
    #expect(afterUnsupported[0].message.contains("stage=capture"))
    #expect(afterUnsupported[0].message.contains("activeState=recording"))
    let rejected = recorder.records.dropFirst(afterUnsupported.count).filter { $0.level == .error }
    #expect(rejected.count == 1)
    #expect(rejected.first?.message.contains("targetState=published") == true)
    #expect(rejected.first?.message.contains("activeState=transcribing") == true)
}

@Test func aStageRunUnderAnotherStagesActiveStateIsRefusedBeforeAnythingIsWritten() async throws {
    let store = try makeStore()
    let id = meetingID("TB03")
    try await store.insertMeeting(makeMeeting(id: id, state: "summarizing"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    await #expect(throws: StageRunner.TransitionError.unsupportedStage(stage: .persist, activeState: .summarizing)) {
        try await runner.run(stage: .persist, meetingID: resolvedID, activeState: .summarizing) {
            .completed(targetState: .published)
        }
    }
    #expect(try await store.fetchStageEvents(meetingID: id).isEmpty)
    #expect(try await store.fetchMeeting(id: id)?.state == "summarizing")
}

@Test func everyStaleTransitionTargetIsInTheTransitionTable() throws {
    #expect(Set(StageRunner.staleDetectionBudgetSeconds.keys) == [.transcribing, .reviewingDiarization, .summarizing, .persisting, .published])

    for activeState in StageRunner.staleDetectionBudgetSeconds.keys {
        let stale = try #require(StageRunner.staleTransition(for: activeState), "\(activeState)")
        let stage = try #require(ActiveStageInFlight.stage(for: activeState), "\(activeState)")
        let allowed = try #require(PipelineTransitions.allowedTargets(stage: stage, activeState: activeState), "\(stage) under \(activeState)")

        #expect(allowed.contains(stale.targetState), "\(stage) under \(activeState) must allow \(stale.targetState)")
    }
}

// MARK: - `run`: duration

@Test func runSetsWholeMillisecondDurationOnCompletedFromTxnAsClockRead() async throws {
    let store = try makeStore()
    let id = meetingID("DRA1")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let start = Date(timeIntervalSince1970: 1_735_000_000)
    let clock = SteppingClock([start, start.addingTimeInterval(2.5)])
    let runner = makeRunner(store: store, now: { clock.now() })
    let resolvedID = try #require(MeetingID(ulid: id))

    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .completed(targetState: .transcribing)
    }

    let events = try await store.fetchStageEvents(meetingID: id)
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(events[0].durationMS == nil)
    #expect(events[1].durationMS == 2500)
    #expect(events[0].occurredAt == isoString(start))
    #expect(events[1].occurredAt == isoString(start.addingTimeInterval(2.5)))
    #expect(clock.callCount == 2)
}

@Test func runSetsDurationOnFailedToo() async throws {
    let store = try makeStore()
    let id = meetingID("DRA2")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let start = Date(timeIntervalSince1970: 1_735_000_000)
    let clock = SteppingClock([start, start.addingTimeInterval(0.75)])
    let runner = makeRunner(store: store, now: { clock.now() })
    let resolvedID = try #require(MeetingID(ulid: id))

    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .failed(targetState: .transcriptionFailed, errorClass: "audio_missing")
    }

    let events = try await store.fetchStageEvents(meetingID: id)
    #expect(events[0].durationMS == nil)
    #expect(events[1].durationMS == 750)
}

@Test func aClockThatRunsBackwardsGivesAZeroDurationNotANegativeOne() async throws {
    let store = try makeStore()
    let id = meetingID("DRA3")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let start = Date(timeIntervalSince1970: 1_735_000_000)
    let clock = SteppingClock([start, start.addingTimeInterval(-5)])
    let runner = makeRunner(store: store, now: { clock.now() })
    let resolvedID = try #require(MeetingID(ulid: id))

    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .completed(targetState: .transcribing)
    }

    // Not by position: events are ordered by `occurred_at`, and this clock
    // stamped the completion before the start.
    let completed = try #require(try await store.fetchStageEvents(meetingID: id).first { $0.event == "completed" })
    #expect(completed.durationMS == 0)
}

// MARK: - `run`: logging

@Test func runLogsEachTransitionAtInfo() async throws {
    let store = try makeStore()
    let id = meetingID("XGG1")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let recorder = LogRecorder()
    let runner = makeRunner(store: store, log: recorder.log)
    let resolvedID = try #require(MeetingID(ulid: id))

    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .completed(targetState: .reviewingDiarization)
    }

    let records = recorder.records
    #expect(records.map(\.level) == [.info, .info])
    #expect(records[0].message.contains("event=started"))
    #expect(records[0].message.contains("state=transcribing"))
    #expect(records[1].message.contains("event=completed"))
    #expect(records[1].message.contains("state=reviewing_diarization"))
    #expect(records.allSatisfy { $0.message.contains("meetingID=\(id)") && $0.message.contains("stage=transcribe") })
}

@Test func runLogsAMoveIntoAFailedStateAsOneErrorRecordCarryingOnlyTaggedFields() async throws {
    let store = try makeStore()
    let id = meetingID("XGG2")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let recorder = LogRecorder()
    let runner = makeRunner(store: store, log: recorder.log)
    let resolvedID = try #require(MeetingID(ulid: id))
    let leakedPath = "/Users/someone/private vault/note.md"

    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .failed(targetState: .transcriptionFailed, errorClass: "audio_missing", errorMessage: "could not open \(leakedPath)")
    }

    let records = recorder.records
    #expect(records.map(\.level) == [.info, .error])
    #expect(records[1].message.contains("event=failed"))
    #expect(records[1].message.contains("state=transcription_failed"))
    #expect(records[1].message.contains("errorClass=audio_missing"))
    #expect(records.allSatisfy { !$0.message.contains(leakedPath) && !$0.message.contains("private vault") })
}

@Test func runLogsABenignFailedEventThatTargetsANonFailureStateAtInfo() async throws {
    let store = try makeStore()
    let id = meetingID("XGG3")
    try await store.insertMeeting(makeMeeting(id: id, state: "reviewing_diarization"))
    let recorder = LogRecorder()
    let runner = makeRunner(store: store, log: recorder.log)
    let resolvedID = try #require(MeetingID(ulid: id))

    _ = try await runner.run(stage: .reviewDiarization, meetingID: resolvedID, activeState: .reviewingDiarization) {
        .failed(targetState: .awaitingAttribution, errorClass: "ai_reviewer_timeout")
    }

    #expect(recorder.records.map(\.level) == [.info, .info])
}

@Test func aRejectedMetadataPayloadIsLoggedRedactedNotPublicSafe() async throws {
    let store = try makeStore()
    let id = meetingID("XGG4")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let recorder = LogRecorder()
    let runner = makeRunner(store: store, log: recorder.log)
    let resolvedID = try #require(MeetingID(ulid: id))
    let notAnObject = "\"/Users/someone/vault/Meetings/note.md\""

    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .failed(targetState: .transcriptionFailed, errorClass: "audio_missing", metadataJSON: notAnObject)
    }

    let warning = try #require(recorder.records.first { $0.level == .default })
    #expect(warning.message.contains("metadataJSON=\(Log.redactionMarker)"))
    #expect(recorder.records.allSatisfy { !$0.message.contains("/Users/someone") })
}
