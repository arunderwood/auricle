import Core
import GRDB
import Testing
@testable import State
@testable import Telemetry

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: try DatabaseQueue())
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

@Test func firstWriteForAMeetingCreatesASparseRowWithOnlyThosePatchColumnsSet() async throws {
    let store = try makeStore()
    let id = meetingID("TR01")
    try await store.insertMeeting(makeMeeting(id: id.rawValue))
    let recorder = TelemetryRecorder(stateStore: store)

    try await recorder.record(meetingID: id, patch: State.Telemetry(
        meetingID: id.rawValue,
        summarizationPath: "claude_api",
        summarizationModel: "claude-opus-5",
        costUSD: 0.32
    ))

    let fetched = try #require(try await store.fetchTelemetry(meetingID: id.rawValue))
    #expect(fetched.summarizationPath == "claude_api")
    #expect(fetched.summarizationModel == "claude-opus-5")
    #expect(fetched.costUSD == 0.32)
    #expect(fetched.diarizationSuggestionsCount == nil)
    #expect(fetched.timeToVaultNoteSeconds == nil)
}

@Test func secondWriteToDifferentColumnsLeavesTheFirstWritersColumnsIntact() async throws {
    let store = try makeStore()
    let id = meetingID("TR02")
    try await store.insertMeeting(makeMeeting(id: id.rawValue))
    let recorder = TelemetryRecorder(stateStore: store)

    try await recorder.record(meetingID: id, patch: State.Telemetry(
        meetingID: id.rawValue,
        summarizationPath: "claude_api",
        summarizationModel: "claude-opus-5",
        costUSD: 0.32
    ))
    try await recorder.record(meetingID: id, patch: State.Telemetry(
        meetingID: id.rawValue,
        diarizationSuggestionsCount: 5,
        diarizationSuggestionsAppliedCount: 3,
        diarizationReviewModel: "claude-haiku-4-5"
    ))

    let fetched = try #require(try await store.fetchTelemetry(meetingID: id.rawValue))
    // The first writer's columns, from the earlier UPSERT, are untouched.
    #expect(fetched.summarizationPath == "claude_api")
    #expect(fetched.summarizationModel == "claude-opus-5")
    #expect(fetched.costUSD == 0.32)
    // The second writer's columns are now present alongside them.
    #expect(fetched.diarizationSuggestionsCount == 5)
    #expect(fetched.diarizationSuggestionsAppliedCount == 3)
    #expect(fetched.diarizationReviewModel == "claude-haiku-4-5")
}

@Test func aThirdWriteOverwritingAnAlreadySetColumnReplacesOnlyThatColumn() async throws {
    let store = try makeStore()
    let id = meetingID("TR03")
    try await store.insertMeeting(makeMeeting(id: id.rawValue))
    let recorder = TelemetryRecorder(stateStore: store)

    try await recorder.record(meetingID: id, patch: State.Telemetry(meetingID: id.rawValue, costUSD: 0.10))
    try await recorder.record(meetingID: id, patch: State.Telemetry(meetingID: id.rawValue, quoteValidationDropCount: 1))
    try await recorder.record(meetingID: id, patch: State.Telemetry(meetingID: id.rawValue, costUSD: 0.45))

    let fetched = try #require(try await store.fetchTelemetry(meetingID: id.rawValue))
    #expect(fetched.costUSD == 0.45)
    #expect(fetched.quoteValidationDropCount == 1)
}

@Test func recordStampsTheMeetingIDParameterEvenIfThePatchsOwnFieldDiffers() async throws {
    let store = try makeStore()
    let id = meetingID("TR04")
    try await store.insertMeeting(makeMeeting(id: id.rawValue))
    let recorder = TelemetryRecorder(stateStore: store)

    try await recorder.record(
        meetingID: id,
        patch: State.Telemetry(meetingID: "wrong-id-should-be-overwritten", costUSD: 0.05)
    )

    let fetched = try #require(try await store.fetchTelemetry(meetingID: id.rawValue))
    #expect(fetched.meetingID == id.rawValue)
    #expect(fetched.costUSD == 0.05)
}
