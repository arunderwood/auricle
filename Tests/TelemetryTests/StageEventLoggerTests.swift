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

private func makeMeeting(id: String, state: String) -> Meeting {
    Meeting(id: id, state: state, createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z")
}

// MARK: - `started`/`completed`/`failed`: through `recordStageTransition`

@Test func startedEventWritesStageEventAndUpdatesStateAtomically() async throws {
    let store = try makeStore()
    let id = meetingID("SG1")
    try await store.insertMeeting(makeMeeting(id: id.rawValue, state: "captured"))
    let logger = StageEventLogger(stateStore: store)

    try await logger.record(event: StageEventRecord(
        meetingID: id,
        stage: .transcribe,
        kind: .started,
        occurredAt: "2026-01-01T00:05:00Z",
        targetState: .transcribing
    ))

    let events = try await store.fetchStageEvents(meetingID: id.rawValue)
    #expect(events.map(\.event) == ["started"])
    #expect(events.first?.metadataSchemaVersion == StageEventLogger.currentMetadataSchemaVersion)

    let meeting = try #require(try await store.fetchMeeting(id: id.rawValue))
    #expect(meeting.state == "transcribing")
}

@Test func completedEventWritesStageEventAndUpdatesStateAtomically() async throws {
    let store = try makeStore()
    let id = meetingID("SG2")
    try await store.insertMeeting(makeMeeting(id: id.rawValue, state: "transcribing"))
    let logger = StageEventLogger(stateStore: store)

    try await logger.record(event: StageEventRecord(
        meetingID: id,
        stage: .transcribe,
        kind: .completed,
        occurredAt: "2026-01-01T00:06:00Z",
        targetState: .awaitingAttribution,
        metadataJSON: "{\"model_id\":\"whisper-large-v3-turbo\"}"
    ))

    let events = try await store.fetchStageEvents(meetingID: id.rawValue)
    #expect(events.map(\.event) == ["completed"])
    #expect(events.first?.metadataJSON == "{\"model_id\":\"whisper-large-v3-turbo\"}")
    #expect(events.first?.metadataSchemaVersion == StageEventLogger.currentMetadataSchemaVersion)

    let meeting = try #require(try await store.fetchMeeting(id: id.rawValue))
    #expect(meeting.state == "awaiting_attribution")
}

@Test func failedEventWritesStageEventAndUpdatesStateAtomically() async throws {
    let store = try makeStore()
    let id = meetingID("SG3")
    try await store.insertMeeting(makeMeeting(id: id.rawValue, state: "transcribing"))
    let logger = StageEventLogger(stateStore: store)

    try await logger.record(event: StageEventRecord(
        meetingID: id,
        stage: .transcribe,
        kind: .failed,
        occurredAt: "2026-01-01T00:06:00Z",
        targetState: .transcriptionFailed,
        errorMessage: "model load failed"
    ))

    let events = try await store.fetchStageEvents(meetingID: id.rawValue)
    #expect(events.map(\.event) == ["failed"])
    #expect(events.first?.errorMessage == "model load failed")
    #expect(events.first?.metadataSchemaVersion == StageEventLogger.currentMetadataSchemaVersion)

    let meeting = try #require(try await store.fetchMeeting(id: id.rawValue))
    #expect(meeting.state == "transcription_failed")
}

@Test func startedCompletedAndFailedWithoutATargetStateThrowBeforeTouchingTheStore() async throws {
    let store = try makeStore()
    let id = meetingID("SG4")
    try await store.insertMeeting(makeMeeting(id: id.rawValue, state: "captured"))
    let logger = StageEventLogger(stateStore: store)

    await #expect(throws: StageEventLogger.RecordError.self) {
        try await logger.record(event: StageEventRecord(
            meetingID: id,
            stage: .transcribe,
            kind: .started,
            occurredAt: "2026-01-01T00:05:00Z"
        ))
    }
    await #expect(throws: StageEventLogger.RecordError.self) {
        try await logger.record(event: StageEventRecord(
            meetingID: id,
            stage: .transcribe,
            kind: .completed,
            occurredAt: "2026-01-01T00:05:00Z"
        ))
    }
    await #expect(throws: StageEventLogger.RecordError.self) {
        try await logger.record(event: StageEventRecord(
            meetingID: id,
            stage: .transcribe,
            kind: .failed,
            occurredAt: "2026-01-01T00:05:00Z"
        ))
    }

    let events = try await store.fetchStageEvents(meetingID: id.rawValue)
    #expect(events.isEmpty)
}

// MARK: - `retried`: through `insertStageEvent`, no state change

@Test func retriedEventWritesStageEventOnlyAndLeavesStateUnchanged() async throws {
    let store = try makeStore()
    let id = meetingID("SG5")
    try await store.insertMeeting(makeMeeting(id: id.rawValue, state: "summarizing"))
    let logger = StageEventLogger(stateStore: store)

    try await logger.record(event: StageEventRecord(
        meetingID: id,
        stage: .summarize,
        kind: .retried,
        occurredAt: "2026-01-01T00:07:00Z",
        durationMS: 1500,
        metadataJSON: "{\"attempt_number\":2}"
    ))

    let events = try await store.fetchStageEvents(meetingID: id.rawValue)
    #expect(events.map(\.event) == ["retried"])
    #expect(events.first?.durationMS == 1500)
    #expect(events.first?.metadataJSON == "{\"attempt_number\":2}")
    #expect(events.first?.metadataSchemaVersion == StageEventLogger.currentMetadataSchemaVersion)

    let meeting = try #require(try await store.fetchMeeting(id: id.rawValue))
    #expect(meeting.state == "summarizing")
}

@Test func retriedEventWithATargetStateThrowsBeforeTouchingTheStore() async throws {
    let store = try makeStore()
    let id = meetingID("SG6")
    try await store.insertMeeting(makeMeeting(id: id.rawValue, state: "summarizing"))
    let logger = StageEventLogger(stateStore: store)

    await #expect(throws: StageEventLogger.RecordError.self) {
        try await logger.record(event: StageEventRecord(
            meetingID: id,
            stage: .summarize,
            kind: .retried,
            occurredAt: "2026-01-01T00:07:00Z",
            targetState: .summarizing
        ))
    }

    let events = try await store.fetchStageEvents(meetingID: id.rawValue)
    #expect(events.isEmpty)
}
