import Core
import Foundation
import GRDB
@testable import State
import Testing

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

private func makeMeeting(id: String = "01STATESTORETESTMEETING00") -> Meeting {
    Meeting(
        id: id,
        state: "recording",
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z",
        captureStartedAt: "2026-01-01T00:00:00Z",
        captureEndedAt: nil,
        durationSeconds: nil,
        title: "Tuesday Sync",
        calendarEventID: "google:abc123",
        vaultNotePath: nil,
        audioCachePath: "/tmp/01STATESTORETESTMEETING00/audio.wav",
        verifiedAt: nil,
        retentionPolicy: nil,
    )
}

@Test func meetingRoundTripsLosslesslyThroughStateStore() async throws {
    let store = try makeStore()
    let original = makeMeeting()

    try await store.insertMeeting(original)
    let fetched = try await store.fetchMeeting(id: original.id)

    #expect(fetched == original)
}

@Test func fetchPendingExcludesTerminalStates() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting(id: "01PENDINGMEETINGIDAAAAAAA").with(state: "transcribing"))
    try await store.insertMeeting(makeMeeting(id: "01VERIFIEDMEETINGIDAAAAAA").with(state: "verified"))
    try await store.insertMeeting(makeMeeting(id: "01DISCARDEDMEETINGIDAAAAA").with(state: "discarded"))
    try await store.insertMeeting(makeMeeting(id: "01EXPIREDMEETINGIDAAAAAAA").with(state: "retention_expired"))

    let pending = try await store.fetchPending()

    #expect(pending.map(\.id).sorted() == ["01PENDINGMEETINGIDAAAAAAA"])
}

@Test func fetchPendingExcludesExactlyThePipelineStatesListedAsTerminal() async throws {
    let store = try makeStore()
    for (index, state) in PipelineState.allCases.enumerated() {
        let id = "01ALLSTATESMEETINGID\(String(format: "%06d", index))"
        try await store.insertMeeting(makeMeeting(id: id).with(state: state.rawValue))
    }

    let pendingStates = try await Set(store.fetchPending().map(\.state))

    let nonTerminal = Set(PipelineState.allCases).subtracting(PipelineState.terminal)
    #expect(pendingStates == Set(nonTerminal.map(\.rawValue)))
}

// MARK: - Column-scoped writers

@Test func setVaultNotePathWritesOnlyThatColumn() async throws {
    let store = try makeStore()
    let original = makeMeeting()
    try await store.insertMeeting(original)

    try await store.setVaultNotePath(meetingID: original.id, path: "/vault/Meetings/2026-01-01 Tuesday Sync.md")

    let fetched = try #require(try await store.fetchMeeting(id: original.id))
    #expect(fetched.vaultNotePath == "/vault/Meetings/2026-01-01 Tuesday Sync.md")
    var expected = original
    expected.vaultNotePath = fetched.vaultNotePath
    expected.updatedAt = fetched.updatedAt
    #expect(fetched == expected)
}

@Test func setCalendarMatchWritesOnlyTheTitleAndEventID() async throws {
    let store = try makeStore()
    let original = makeMeeting()
    try await store.insertMeeting(original)

    try await store.setCalendarMatch(meetingID: original.id, title: "Weekly Sync", calendarEventID: "google:evt123")

    let fetched = try #require(try await store.fetchMeeting(id: original.id))
    #expect(fetched.title == "Weekly Sync")
    #expect(fetched.calendarEventID == "google:evt123")
    var expected = original
    expected.title = "Weekly Sync"
    expected.calendarEventID = "google:evt123"
    expected.updatedAt = fetched.updatedAt
    #expect(fetched == expected)
}

@Test func theColumnWritersThrowMeetingNotFoundForAMissingRow() async throws {
    let store = try makeStore()

    await #expect(throws: StateStoreError.meetingNotFound(id: "01MISSINGMEETINGID0000000")) {
        try await store.setVaultNotePath(meetingID: "01MISSINGMEETINGID0000000", path: "/vault/note.md")
    }
    await #expect(throws: StateStoreError.meetingNotFound(id: "01MISSINGMEETINGID0000000")) {
        try await store.setCalendarMatch(meetingID: "01MISSINGMEETINGID0000000", title: "T", calendarEventID: "E")
    }
}

// MARK: - Guarded state transitions

private func transition(
    _ store: StateStore,
    id: String = "01STATESTORETESTMEETING00",
    to targetState: String,
    event: String = "completed",
    expectedState: String? = nil,
    expectedUpdatedAt: String? = nil,
) async throws {
    try await store.recordStageTransition(
        meetingID: id,
        stage: "summarize",
        event: event,
        occurredAt: "2026-01-01T00:10:00Z",
        targetState: targetState,
        expectedState: expectedState,
        expectedUpdatedAt: expectedUpdatedAt,
    )
}

@Test func aGuardedTransitionLandsWhenTheRowStillMatchesWhatWasRead() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting().with(state: "summarizing"))
    let read = try #require(try await store.fetchMeeting(id: "01STATESTORETESTMEETING00"))

    try await transition(store, to: "summarization_failed", event: "failed", expectedState: "summarizing", expectedUpdatedAt: read.updatedAt)

    let after = try #require(try await store.fetchMeeting(id: "01STATESTORETESTMEETING00"))
    #expect(after.state == "summarization_failed")
    #expect(try await store.fetchStageEvents(meetingID: "01STATESTORETESTMEETING00").map(\.event) == ["failed"])
}

/// The row read at `updated_at` T, then a real write that leaves `state`
/// unchanged, as a stage completing into its own active state does. State
/// alone cannot tell the two apart; `updated_at` can.
@Test func aSameStateWriteAfterTheReadMakesAGuardedTransitionStale() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting().with(state: "summarizing"))
    let read = try #require(try await store.fetchMeeting(id: "01STATESTORETESTMEETING00"))

    try await transition(store, to: "summarizing", expectedState: "summarizing")
    let eventsBefore = try await store.fetchStageEvents(meetingID: "01STATESTORETESTMEETING00")

    await #expect(throws: StateStoreError.staleWrite(id: "01STATESTORETESTMEETING00")) {
        try await transition(store, to: "summarization_failed", event: "failed", expectedState: "summarizing", expectedUpdatedAt: read.updatedAt)
    }

    let after = try #require(try await store.fetchMeeting(id: "01STATESTORETESTMEETING00"))
    #expect(after.state == "summarizing")
    #expect(try await store.fetchStageEvents(meetingID: "01STATESTORETESTMEETING00") == eventsBefore)
}

@Test func aGuardedTransitionWhoseExpectedStateDiffersIsStaleAndRollsTheEventBack() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting().with(state: "published"))

    await #expect(throws: StateStoreError.staleWrite(id: "01STATESTORETESTMEETING00")) {
        try await transition(store, to: "summarization_failed", event: "failed", expectedState: "summarizing")
    }

    let after = try #require(try await store.fetchMeeting(id: "01STATESTORETESTMEETING00"))
    #expect(after.state == "published")
    #expect(try await store.fetchStageEvents(meetingID: "01STATESTORETESTMEETING00").isEmpty)
}

@Test func anUnguardedTransitionStillWritesWhateverTheCurrentState() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting().with(state: "published"))

    try await transition(store, to: "summarizing", event: "started")

    #expect(try await store.fetchMeeting(id: "01STATESTORETESTMEETING00")?.state == "summarizing")
}

@Test func aGuardedTransitionForAMissingMeetingIsMeetingNotFoundNotStale() async throws {
    let store = try makeStore()

    await #expect(throws: StateStoreError.meetingNotFound(id: "01MISSINGMEETINGID0000000")) {
        try await transition(
            store,
            id: "01MISSINGMEETINGID0000000",
            to: "summarization_failed",
            event: "failed",
            expectedState: "summarizing",
            expectedUpdatedAt: "2026-01-01T00:00:00Z",
        )
    }
    await #expect(throws: StateStoreError.meetingNotFound(id: "01MISSINGMEETINGID0000000")) {
        try await transition(store, id: "01MISSINGMEETINGID0000000", to: "summarizing", event: "started")
    }
    #expect(try await store.fetchStageEvents(meetingID: "01MISSINGMEETINGID0000000").isEmpty)
}

@Test func stageEventRoundTripsAndAssignsAutoincrementedID() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting())

    let event = StageEvent(
        meetingID: "01STATESTORETESTMEETING00",
        stage: "transcribe",
        event: "started",
        occurredAt: "2026-01-01T00:05:00Z",
    )
    let inserted = try await store.insertStageEvent(event)
    #expect(inserted.id != nil)

    let events = try await store.fetchStageEvents(meetingID: "01STATESTORETESTMEETING00")
    #expect(events.count == 1)
    #expect(events.first?.stage == "transcribe")
    #expect(events.first?.event == "started")
    #expect(events.first?.id == inserted.id)
}

/// Records executed SQL from a connection's trace hook, which runs off the test's actor.
private final class StatementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var statements: [String] = []

    func append(_ sql: String) {
        lock.withLock { statements.append(sql) }
    }

    var all: [String] {
        lock.withLock { statements }
    }
}

@Test func fetchStageEventsOrdersSameSecondEventsByID() async throws {
    let statements = StatementLog()
    var configuration = Configuration()
    configuration.prepareDatabase { db in
        db.trace { event in
            if case let .statement(statement) = event {
                statements.append(statement.sql)
            }
        }
    }
    let store = try StateStore.forTesting(writer: DatabaseQueue(configuration: configuration))
    try await store.insertMeeting(makeMeeting())
    let sameSecond = "2026-01-01T00:05:00Z"
    for (stage, event, occurredAt) in [
        ("transcribe", "started", sameSecond),
        ("transcribe", "completed", sameSecond),
        ("capture", "completed", "2026-01-01T00:04:59Z"),
    ] {
        _ = try await store.insertStageEvent(
            StageEvent(meetingID: "01STATESTORETESTMEETING00", stage: stage, event: event, occurredAt: occurredAt),
        )
    }

    let events = try await store.fetchStageEvents(meetingID: "01STATESTORETESTMEETING00")

    #expect(events.map { "\($0.stage) \($0.event)" } == ["capture completed", "transcribe started", "transcribe completed"])
    // SQLite returns rows that tie on `occurred_at` in rowid order, so the result alone
    // cannot tell this query from one with no tiebreak. Assert the clause that makes the
    // order part of the contract.
    let select = try #require(statements.all.last { $0.contains("FROM \"stage_events\"") })
    #expect(select.contains("ORDER BY \"occurred_at\", \"id\""))
}

@Test func retentionTimerRoundTripsLosslessly() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting())

    let timer = RetentionTimer(
        meetingID: "01STATESTORETESTMEETING00",
        armedAt: "2026-01-01T01:00:00Z",
        firesAt: "2026-01-31T01:00:00Z",
    )
    try await store.insertRetentionTimer(timer)

    let fetched = try await store.fetchRetentionTimer(meetingID: "01STATESTORETESTMEETING00")
    #expect(fetched?.armedAt == timer.armedAt)
    #expect(fetched?.firesAt == timer.firesAt)
    #expect(fetched?.status == "pending")
}

@Test func telemetryRoundTripsEveryColumnLosslessly() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting())

    let telemetry = Telemetry(
        meetingID: "01STATESTORETESTMEETING00",
        timeToAttributionReadySeconds: 120,
        timeToVaultNoteSeconds: 600,
        transcriptionWEREstimate: 0.08,
        quoteValidationDropCount: 2,
        attributionCompletionPath: "inline_ui",
        summarizationPath: "claude_api",
        summarizationModel: "claude-opus-5",
        summarizationEffortBudget: "high",
        costUSD: 0.32,
        diarizationSuggestionsCount: 5,
        diarizationSuggestionsAppliedCount: 3,
        diarizationSuggestionsRejectedCount: 2,
        diarizationReviewCostUSD: 0.01,
        diarizationReviewModel: "claude-haiku-4-5",
        transcriptionSuggestionsCount: nil,
        transcriptionSuggestionsAppliedCount: nil,
        transcriptionSuggestionsRejectedCount: nil,
        transcriptionReviewCostUSD: nil,
        transcriptionReviewModel: nil,
        audioRetentionStatusAtSnapshot: "retained",
        groundingMethod: "citations",
        summarizationPromptSetHash: String(repeating: "ab", count: 32),
    )
    try await store.insertTelemetry(telemetry)

    let fetched = try #require(try await store.fetchTelemetry(meetingID: "01STATESTORETESTMEETING00"))
    #expect(fetched == telemetry)
}

@Test func upsertKeepsGroundingMethodAndPromptSetHashWhenThePatchLeavesThemNilAndReplacesThemWhenSet() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting())
    let id = "01STATESTORETESTMEETING00"
    let hash = String(repeating: "cd", count: 32)

    try await store.upsertTelemetry(Telemetry(meetingID: id, groundingMethod: "substring", summarizationPromptSetHash: hash))
    try await store.upsertTelemetry(Telemetry(meetingID: id, costUSD: 0.10))

    let afterUnrelatedPatch = try #require(try await store.fetchTelemetry(meetingID: id))
    #expect(afterUnrelatedPatch.groundingMethod == "substring")
    #expect(afterUnrelatedPatch.summarizationPromptSetHash == hash)
    #expect(afterUnrelatedPatch.costUSD == 0.10)

    let replacementHash = String(repeating: "ef", count: 32)
    try await store.upsertTelemetry(Telemetry(meetingID: id, groundingMethod: "citations", summarizationPromptSetHash: replacementHash))

    let afterReplacement = try #require(try await store.fetchTelemetry(meetingID: id))
    #expect(afterReplacement.groundingMethod == "citations")
    #expect(afterReplacement.summarizationPromptSetHash == replacementHash)
    #expect(afterReplacement.costUSD == 0.10)
}

private extension Meeting {
    func with(state: String) -> Meeting {
        var copy = self
        copy.state = state
        return copy
    }
}
