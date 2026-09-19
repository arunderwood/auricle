import Core
import Foundation
import GRDB
@testable import Orchestrator
@testable import State
@testable import Telemetry
import Testing

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

/// Every test constructs its `StageRunner` through this helper rather than
/// calling the initializer directly: the `StageEventLogger` must be backed
/// by the same `StateStore` the test asserts against afterward, and
/// spelling that out at every call site would just repeat this line.
private func makeRunner(store: StateStore, now: @escaping @Sendable () -> Date = { Date() }) -> StageRunner {
    StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store), now: now)
}

/// A 26-character, Crockford-base32-safe (no `I`/`L`/`O`/`U`) stand-in ULID:
/// `MeetingID(ulid:)` validates its shape, and `StageRunner`'s sweep/crash
/// paths silently skip any row that fails that validation, so fixtures here
/// must actually pass it rather than reuse arbitrary human-readable IDs.
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

private struct StubWorkError: Error, Equatable {}

// MARK: - `run`: the two-transaction pattern

@Test func runOnCompletedWritesBothTransactionsAndEndsAtTargetState() async throws {
    let store = try makeStore()
    let id = meetingID("GD01")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    let outcome = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .completed(targetState: .reviewingDiarization)
    }

    guard case let .completed(targetState, _) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .reviewingDiarization)

    let events = try await store.fetchStageEvents(meetingID: id)
    #expect(events.map(\.event) == ["started", "completed"])
    #expect(events.allSatisfy { $0.stage == "transcribe" })

    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "reviewing_diarization")
}

@Test func runOnFailedWritesBothTransactionsAndFoldsErrorClassIntoMetadata() async throws {
    let store = try makeStore()
    let id = meetingID("BAD1")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    _ = try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
        .failed(
            targetState: .transcriptionFailed,
            errorClass: "whisperkit_oom",
            errorMessage: "model load failed",
            metadataJSON: "{\"cost_usd\":0.5}",
        )
    }

    let events = try await store.fetchStageEvents(meetingID: id)
    #expect(events.map(\.event) == ["started", "failed"])

    let failedEvent = try #require(events.last)
    #expect(failedEvent.errorMessage == "model load failed")
    let metadataJSON = try #require(failedEvent.metadataJSON)
    #expect(metadataJSON.contains("\"error_class\":\"whisperkit_oom\""))
    #expect(metadataJSON.contains("\"cost_usd\":0.5"))

    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "transcription_failed")
}

@Test func runPropagatesAThrownErrorAndSkipsTxnB() async throws {
    let store = try makeStore()
    let id = meetingID("THR1")
    try await store.insertMeeting(makeMeeting(id: id, state: "captured"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    await #expect(throws: StubWorkError.self) {
        try await runner.run(stage: .transcribe, meetingID: resolvedID, activeState: .transcribing) {
            throw StubWorkError()
        }
    }

    // Txn A landed; Txn B never ran — this is deliberately indistinguishable
    // from a real subprocess crash between the two, which is what the
    // stale-detection sweep and crash recovery exist to reconcile.
    let events = try await store.fetchStageEvents(meetingID: id)
    #expect(events.map(\.event) == ["started"])

    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "transcribing")
}

// MARK: - `synthesizeFailure`: the per-state stale-transition table

@Test func synthesizeFailureOnReviewingDiarizationIsABenignPassthroughNotAFailedState() async throws {
    let store = try makeStore()
    let id = meetingID("RVD3")
    try await store.insertMeeting(makeMeeting(id: id, state: "reviewing_diarization"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    try await runner.synthesizeFailure(
        meetingID: resolvedID,
        stage: .reviewDiarization,
        activeState: .reviewingDiarization,
        reason: .staleActiveState(budgetSeconds: 90),
    )

    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "awaiting_attribution")

    let events = try await store.fetchStageEvents(meetingID: id)
    let failedEvent = try #require(events.first { $0.event == "failed" })
    #expect(failedEvent.metadataJSON?.contains("\"error_class\":\"ai_reviewer_timeout\"") == true)
}

@Test func synthesizeFailureOnPublishedIsABenignPassthroughNotAFailedState() async throws {
    let store = try makeStore()
    let id = meetingID("PBD3")
    try await store.insertMeeting(makeMeeting(id: id, state: "published"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    try await runner.synthesizeFailure(
        meetingID: resolvedID,
        stage: .notify,
        activeState: .published,
        reason: .staleActiveState(budgetSeconds: 30),
    )

    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "awaiting_verification")

    let events = try await store.fetchStageEvents(meetingID: id)
    let failedEvent = try #require(events.first { $0.event == "failed" })
    #expect(failedEvent.metadataJSON?.contains("\"error_class\":\"stale_active_state\"") == true)
}

@Test func synthesizeFailureOnTranscribingTransitionsToTranscriptionFailed() async throws {
    let store = try makeStore()
    let id = meetingID("TRX3")
    try await store.insertMeeting(makeMeeting(id: id, state: "transcribing"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    try await runner.synthesizeFailure(
        meetingID: resolvedID,
        stage: .transcribe,
        activeState: .transcribing,
        reason: .staleActiveState(budgetSeconds: 60),
    )

    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "transcription_failed")

    let events = try await store.fetchStageEvents(meetingID: id)
    let failedEvent = try #require(events.first { $0.event == "failed" })
    #expect(failedEvent.metadataJSON?.contains("\"error_class\":\"stale_active_state\"") == true)
}

@Test func synthesizeFailureOnSummarizingTransitionsToSummarizationFailed() async throws {
    let store = try makeStore()
    let id = meetingID("SMZ3")
    try await store.insertMeeting(makeMeeting(id: id, state: "summarizing"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    try await runner.synthesizeFailure(
        meetingID: resolvedID,
        stage: .summarize,
        activeState: .summarizing,
        reason: .staleActiveState(budgetSeconds: 720),
    )

    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "summarization_failed")

    let events = try await store.fetchStageEvents(meetingID: id)
    let failedEvent = try #require(events.first { $0.event == "failed" })
    #expect(failedEvent.metadataJSON?.contains("\"error_class\":\"stale_active_state\"") == true)
}

@Test func synthesizeFailureOnPersistingTransitionsToPersistFailed() async throws {
    let store = try makeStore()
    let id = meetingID("PRS1")
    try await store.insertMeeting(makeMeeting(id: id, state: "persisting"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    try await runner.synthesizeFailure(
        meetingID: resolvedID,
        stage: .persist,
        activeState: .persisting,
        reason: .staleActiveState(budgetSeconds: 60),
    )

    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "persist_failed")

    let events = try await store.fetchStageEvents(meetingID: id)
    let failedEvent = try #require(events.first { $0.event == "failed" })
    #expect(failedEvent.stage == "persist")
    #expect(failedEvent.metadataJSON?.contains("\"error_class\":\"stale_active_state\"") == true)
}

@Test func synthesizeFailureOnAttributingThrowsSinceItHasNoBudget() async throws {
    let store = try makeStore()
    let id = meetingID("ATB2")
    try await store.insertMeeting(makeMeeting(id: id, state: "attributing"))
    let runner = makeRunner(store: store)
    let resolvedID = try #require(MeetingID(ulid: id))

    do {
        try await runner.synthesizeFailure(
            meetingID: resolvedID,
            stage: .attribute,
            activeState: .attributing,
            reason: .staleActiveState(budgetSeconds: 0),
        )
        Issue.record("expected synthesizeFailure to throw for .attributing")
    } catch let error as StageRunner.SynthesizeFailureError {
        #expect(error == .noStaleTransition(activeState: .attributing))
    }
}

// MARK: - `sweepStaleActiveStates`: one pass over every budgeted state

@Test func sweepTransitionsOnlyMeetingsPastTheirOwnStatesBudget() async throws {
    let store = try makeStore()
    let runner = makeRunner(store: store)
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)

    let staleTranscribing = meetingID("TRX4")
    let freshTranscribing = meetingID("TRX5")
    let staleReview = meetingID("RVD4")
    let freshReview = meetingID("RVD5")
    let staleSummarizing = meetingID("SMZ4")
    let freshSummarizing = meetingID("SMZ5")
    let stalePersisting = meetingID("PRS4")
    let freshPersisting = meetingID("PRS5")
    let stalePublished = meetingID("PBD4")
    let freshPublished = meetingID("PBD5")
    let staleAttributing = meetingID("ATB3")

    func seed(_ id: String, state: String, secondsBeforeNow: Double) async throws {
        try await store.insertMeeting(makeMeeting(id: id, state: state, updatedAt: isoString(fixedNow.addingTimeInterval(-secondsBeforeNow))))
    }

    try await seed(staleTranscribing, state: "transcribing", secondsBeforeNow: 61)
    try await seed(freshTranscribing, state: "transcribing", secondsBeforeNow: 10)
    try await seed(staleReview, state: "reviewing_diarization", secondsBeforeNow: 95)
    try await seed(freshReview, state: "reviewing_diarization", secondsBeforeNow: 10)
    try await seed(staleSummarizing, state: "summarizing", secondsBeforeNow: 725)
    try await seed(freshSummarizing, state: "summarizing", secondsBeforeNow: 10)
    try await seed(stalePersisting, state: "persisting", secondsBeforeNow: 65)
    try await seed(freshPersisting, state: "persisting", secondsBeforeNow: 10)
    try await seed(stalePublished, state: "published", secondsBeforeNow: 35)
    try await seed(freshPublished, state: "published", secondsBeforeNow: 10)
    try await seed(staleAttributing, state: "attributing", secondsBeforeNow: 100_000)

    let transitioned = try await runner.sweepStaleActiveStates(now: fixedNow)
    let transitionedIDs = Set(transitioned.map(\.rawValue))

    #expect(transitionedIDs == Set([staleTranscribing, staleReview, staleSummarizing, stalePersisting, stalePublished]))

    let transcribingMeeting = try #require(try await store.fetchMeeting(id: staleTranscribing))
    #expect(transcribingMeeting.state == "transcription_failed")
    let reviewMeeting = try #require(try await store.fetchMeeting(id: staleReview))
    #expect(reviewMeeting.state == "awaiting_attribution")
    let summarizingMeeting = try #require(try await store.fetchMeeting(id: staleSummarizing))
    #expect(summarizingMeeting.state == "summarization_failed")
    let persistingMeeting = try #require(try await store.fetchMeeting(id: stalePersisting))
    #expect(persistingMeeting.state == "persist_failed")
    let publishedMeeting = try #require(try await store.fetchMeeting(id: stalePublished))
    #expect(publishedMeeting.state == "awaiting_verification")

    #expect(try await store.fetchMeeting(id: freshTranscribing)?.state == "transcribing")
    #expect(try await store.fetchMeeting(id: freshReview)?.state == "reviewing_diarization")
    #expect(try await store.fetchMeeting(id: freshSummarizing)?.state == "summarizing")
    #expect(try await store.fetchMeeting(id: freshPersisting)?.state == "persisting")
    #expect(try await store.fetchMeeting(id: freshPublished)?.state == "published")
    // `attributing` has no budget entry, so it is never swept no matter how stale.
    #expect(try await store.fetchMeeting(id: staleAttributing)?.state == "attributing")
}

/// The `meetings_updated_at` trigger always stamps `updated_at` via
/// `strftime('%Y-%m-%dT%H:%M:%fZ','now')`, which includes fractional
/// seconds — unlike this file's other fixtures (whole seconds only), so
/// `ISO8601UTC.date(from:)`'s fractional-seconds branch, the one production
/// always takes, was never exercised. This seeds a literal in that shape.
@Test func sweepParsesFractionalSecondsUpdatedAtLikeTheProductionTrigger() async throws {
    let store = try makeStore()
    let runner = makeRunner(store: store)

    let updatedAt = "2026-01-01T00:00:00.398Z"
    let plainFormatter = ISO8601DateFormatter()
    plainFormatter.formatOptions = [.withInternetDateTime]
    let updatedAtWholeSecond = try #require(plainFormatter.date(from: "2026-01-01T00:00:00Z"))
    // 65s after the fractional instant above — comfortably past the
    // `transcribing` budget (60s) regardless of the .398s sub-second part,
    // and computed independently of `ISO8601UTC` so this isn't just
    // checking the parser against itself.
    let fixedNow = updatedAtWholeSecond.addingTimeInterval(65)

    let id = meetingID("FRC1")
    try await store.insertMeeting(makeMeeting(id: id, state: "transcribing", updatedAt: updatedAt))

    let transitioned = try await runner.sweepStaleActiveStates(now: fixedNow)

    #expect(transitioned.map(\.rawValue) == [id])
    let meeting = try #require(try await store.fetchMeeting(id: id))
    #expect(meeting.state == "transcription_failed")
}

/// `asOf.timeIntervalSince(updatedAt) >= Double(budgetSeconds)` is
/// inclusive: a meeting exactly at its budget must be treated as stale, not
/// just one strictly past it.
@Test func sweepTreatsExactlyAtBudgetAsStaleButOneSecondUnderAsNotStale() async throws {
    let store = try makeStore()
    let runner = makeRunner(store: store)
    let fixedNow = Date(timeIntervalSince1970: 1_735_000_000)

    let oneSecondUnderBudget = meetingID("BND1")
    let exactlyAtBudget = meetingID("BND2")

    try await store.insertMeeting(makeMeeting(id: oneSecondUnderBudget, state: "transcribing", updatedAt: isoString(fixedNow.addingTimeInterval(-59))))
    try await store.insertMeeting(makeMeeting(id: exactlyAtBudget, state: "transcribing", updatedAt: isoString(fixedNow.addingTimeInterval(-60))))

    let transitioned = try await runner.sweepStaleActiveStates(now: fixedNow)

    #expect(transitioned.map(\.rawValue) == [exactlyAtBudget])
    #expect(try await store.fetchMeeting(id: oneSecondUnderBudget)?.state == "transcribing")
    #expect(try await store.fetchMeeting(id: exactlyAtBudget)?.state == "transcription_failed")
}
