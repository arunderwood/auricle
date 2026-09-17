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

@Test func updateMeetingPersistsChanges() async throws {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting())

    var updated = try #require(try await store.fetchMeeting(id: "01STATESTORETESTMEETING00"))
    updated.state = "captured"
    updated.captureEndedAt = "2026-01-01T00:30:00Z"
    updated.durationSeconds = 1800
    try await store.updateMeeting(updated)

    let fetched = try await store.fetchMeeting(id: "01STATESTORETESTMEETING00")
    #expect(fetched?.state == "captured")
    #expect(fetched?.durationSeconds == 1800)
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
        audioRetentionStatusAt30d: "retained",
    )
    try await store.insertTelemetry(telemetry)

    let fetched = try #require(try await store.fetchTelemetry(meetingID: "01STATESTORETESTMEETING00"))
    #expect(fetched == telemetry)
}

private extension Meeting {
    func with(state: String) -> Meeting {
        var copy = self
        copy.state = state
        return copy
    }
}
