import Core
import GRDB
@testable import State
@testable import Telemetry
import Testing

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

/// A 26-character, Crockford-base32-safe (no `I`/`L`/`O`/`U`) stand-in ULID.
private func meetingID(_ tag: String) -> MeetingID {
    let prefix = "01" + tag
    let raw = prefix + String(repeating: "9", count: 26 - prefix.count)
    return MeetingID(ulid: raw)!
}

private func makeMeeting(id: String) -> Meeting {
    Meeting(id: id, state: "summarizing", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
}

private func makeRecorder(for id: MeetingID) async throws -> (store: StateStore, recorder: TelemetryRecorder) {
    let store = try makeStore()
    try await store.insertMeeting(makeMeeting(id: id.rawValue))
    return (store, TelemetryRecorder(stateStore: store))
}

// MARK: - One patch type per writer

@Test func aSummarizePatchWritesOnlyTheSummarizeWritersColumns() async throws {
    let id = meetingID("TR01")
    let (store, recorder) = try await makeRecorder(for: id)

    try await recorder.record(meetingID: id, patch: SummarizeTelemetryPatch(
        quoteValidationDropCount: 2,
        summarizationPath: "claude_api",
        summarizationModel: "claude-opus-5",
        summarizationEffortBudget: "high",
        costUSD: 0.32,
        summarizationPromptSetHash: String(repeating: "ab", count: 32),
        groundingMethod: "substring",
    ))

    let fetched = try #require(try await store.fetchTelemetry(meetingID: id.rawValue))
    #expect(fetched == State.Telemetry(
        meetingID: id.rawValue,
        quoteValidationDropCount: 2,
        summarizationPath: "claude_api",
        summarizationModel: "claude-opus-5",
        summarizationEffortBudget: "high",
        costUSD: 0.32,
        groundingMethod: "substring",
        summarizationPromptSetHash: String(repeating: "ab", count: 32),
    ))
}

@Test func aTranscribePatchWritesOnlyTheWEREstimate() async throws {
    let id = meetingID("TR02")
    let (store, recorder) = try await makeRecorder(for: id)

    try await recorder.record(meetingID: id, patch: TranscribeTelemetryPatch(transcriptionWEREstimate: 0.08))

    #expect(try await store.fetchTelemetry(meetingID: id.rawValue) == State.Telemetry(meetingID: id.rawValue, transcriptionWEREstimate: 0.08))
}

@Test func aReviewDiarizationPatchWritesOnlyTheReviewersColumns() async throws {
    let id = meetingID("TR03")
    let (store, recorder) = try await makeRecorder(for: id)

    try await recorder.record(meetingID: id, patch: ReviewDiarizationTelemetryPatch(
        diarizationSuggestionsCount: 5,
        diarizationReviewCostUSD: 0.01,
        diarizationReviewModel: "claude-haiku-4-5",
    ))

    #expect(try await store.fetchTelemetry(meetingID: id.rawValue) == State.Telemetry(
        meetingID: id.rawValue,
        diarizationSuggestionsCount: 5,
        diarizationReviewCostUSD: 0.01,
        diarizationReviewModel: "claude-haiku-4-5",
    ))
}

@Test func anAttributePatchWritesOnlyTheCompletionPathAndTheAppliedAndRejectedCounts() async throws {
    let id = meetingID("TR04")
    let (store, recorder) = try await makeRecorder(for: id)

    try await recorder.record(meetingID: id, patch: AttributeTelemetryPatch(
        attributionCompletionPath: "inline_ui",
        diarizationSuggestionsAppliedCount: 3,
        diarizationSuggestionsRejectedCount: 2,
    ))

    #expect(try await store.fetchTelemetry(meetingID: id.rawValue) == State.Telemetry(
        meetingID: id.rawValue,
        attributionCompletionPath: "inline_ui",
        diarizationSuggestionsAppliedCount: 3,
        diarizationSuggestionsRejectedCount: 2,
    ))
}

@Test func aNotifyPatchWritesOnlyTheTwoTimings() async throws {
    let id = meetingID("TR05")
    let (store, recorder) = try await makeRecorder(for: id)

    try await recorder.record(meetingID: id, patch: NotifyTelemetryPatch(timeToAttributionReadySeconds: 95, timeToVaultNoteSeconds: 610))

    #expect(try await store.fetchTelemetry(meetingID: id.rawValue) == State.Telemetry(
        meetingID: id.rawValue,
        timeToAttributionReadySeconds: 95,
        timeToVaultNoteSeconds: 610,
    ))
}

@Test func aRetentionPatchWritesOnlyTheSnapshotStatus() async throws {
    let id = meetingID("TR06")
    let (store, recorder) = try await makeRecorder(for: id)

    try await recorder.record(meetingID: id, patch: RetentionTelemetryPatch(audioRetentionStatusAtSnapshot: "deleted_after_grace"))

    #expect(try await store.fetchTelemetry(meetingID: id.rawValue) == State.Telemetry(
        meetingID: id.rawValue,
        audioRetentionStatusAtSnapshot: "deleted_after_grace",
    ))
}

@Test func everyPatchYieldsARecordWithNoOtherColumnSet() {
    let id = meetingID("TR07")
    let empty = State.Telemetry(meetingID: id.rawValue)

    #expect(SummarizeTelemetryPatch().telemetry(for: id) == empty)
    #expect(TranscribeTelemetryPatch().telemetry(for: id) == empty)
    #expect(ReviewDiarizationTelemetryPatch().telemetry(for: id) == empty)
    #expect(AttributeTelemetryPatch().telemetry(for: id) == empty)
    #expect(NotifyTelemetryPatch().telemetry(for: id) == empty)
    #expect(RetentionTelemetryPatch().telemetry(for: id) == empty)
}

// MARK: - Writers stay out of each other's columns

@Test func aSecondWritersPatchLeavesTheFirstWritersColumnsIntact() async throws {
    let id = meetingID("TR08")
    let (store, recorder) = try await makeRecorder(for: id)

    try await recorder.record(meetingID: id, patch: SummarizeTelemetryPatch(
        summarizationPath: "claude_api",
        summarizationModel: "claude-opus-5",
        costUSD: 0.32,
    ))
    try await recorder.record(meetingID: id, patch: ReviewDiarizationTelemetryPatch(
        diarizationSuggestionsCount: 5,
        diarizationReviewModel: "claude-haiku-4-5",
    ))

    let fetched = try #require(try await store.fetchTelemetry(meetingID: id.rawValue))
    #expect(fetched.summarizationPath == "claude_api")
    #expect(fetched.summarizationModel == "claude-opus-5")
    #expect(fetched.costUSD == 0.32)
    #expect(fetched.diarizationSuggestionsCount == 5)
    #expect(fetched.diarizationReviewModel == "claude-haiku-4-5")
}

@Test func theSameWritersLaterPatchReplacesOnlyTheColumnItSets() async throws {
    let id = meetingID("TR09")
    let (store, recorder) = try await makeRecorder(for: id)

    try await recorder.record(meetingID: id, patch: SummarizeTelemetryPatch(costUSD: 0.10))
    try await recorder.record(meetingID: id, patch: SummarizeTelemetryPatch(quoteValidationDropCount: 1))
    try await recorder.record(meetingID: id, patch: SummarizeTelemetryPatch(costUSD: 0.45))

    let fetched = try #require(try await store.fetchTelemetry(meetingID: id.rawValue))
    #expect(fetched.costUSD == 0.45)
    #expect(fetched.quoteValidationDropCount == 1)
}

@Test func theRowIsKeyedByTheMeetingIDPassedToRecord() async throws {
    let store = try makeStore()
    let first = meetingID("TR10")
    let second = meetingID("TR11")
    try await store.insertMeeting(makeMeeting(id: first.rawValue))
    try await store.insertMeeting(makeMeeting(id: second.rawValue))
    let recorder = TelemetryRecorder(stateStore: store)

    try await recorder.record(meetingID: second, patch: SummarizeTelemetryPatch(costUSD: 0.05))

    #expect(try await store.fetchTelemetry(meetingID: first.rawValue) == nil)
    let fetched = try #require(try await store.fetchTelemetry(meetingID: second.rawValue))
    #expect(fetched.meetingID == second.rawValue)
    #expect(fetched.costUSD == 0.05)
}
