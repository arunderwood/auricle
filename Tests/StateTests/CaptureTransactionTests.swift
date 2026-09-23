import Foundation
import GRDB
@testable import State
import Testing

private let meetingID = "01CAPTURETXNTESTMEETING00"

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

private func recordingMeeting(id: String = meetingID) -> Meeting {
    Meeting(
        id: id,
        state: "recording",
        createdAt: "2026-09-22T10:00:00Z",
        updatedAt: "2026-09-22T10:00:00Z",
        captureStartedAt: "2026-09-22T10:00:00Z",
        audioCachePath: "/tmp/\(id)/audio.wav",
        captureTimeZone: "America/Los_Angeles",
    )
}

private func captureEvent(_ kind: String, id: Int64? = nil, meeting: String = meetingID, stage: String = "capture") -> StageEvent {
    StageEvent(id: id, meetingID: meeting, stage: stage, event: kind, occurredAt: "2026-09-22T10:00:00Z", metadataSchemaVersion: 1)
}

@Test func beginCaptureWritesTheRowAndTheStartedEventTogether() async throws {
    let store = try makeStore()
    try await store.beginCapture(meeting: recordingMeeting(), event: captureEvent("started"))

    let meeting = try #require(try await store.fetchMeeting(id: meetingID))
    #expect(meeting == recordingMeeting())
    #expect(try await store.fetchStageEvents(meetingID: meetingID).map(\.event) == ["started"])
}

@Test func beginCaptureRefusesAnEventThatIsNotThisMeetingsCaptureStart() async throws {
    let store = try makeStore()
    for event in [captureEvent("completed"), captureEvent("started", stage: "transcribe"), captureEvent("started", meeting: "01SOMEOTHERMEETINGID00000")] {
        await #expect(throws: StateStoreError.invalidCaptureEvent(id: meetingID)) {
            try await store.beginCapture(meeting: recordingMeeting(), event: event)
        }
    }
    #expect(try await store.fetchMeeting(id: meetingID) == nil)
}

/// An event whose insert fails takes the row down with it: a `recording` row
/// with no `started` event is never left behind.
@Test func beginCaptureRollsTheRowBackWhenTheEventInsertFails() async throws {
    let store = try makeStore()
    let other = "01CAPTURETXNOTHERMEETING0"
    try await store.beginCapture(meeting: recordingMeeting(id: other), event: captureEvent("started", meeting: other))
    let takenID = try #require(try await store.fetchStageEvents(meetingID: other).first?.id)

    await #expect(throws: (any Error).self) {
        try await store.beginCapture(meeting: recordingMeeting(), event: captureEvent("started", id: takenID))
    }
    #expect(try await store.fetchMeeting(id: meetingID) == nil)
}

@Test func finishCaptureWritesEndDurationStateAndEventTogether() async throws {
    let store = try makeStore()
    try await store.beginCapture(meeting: recordingMeeting(), event: captureEvent("started"))

    try await store.finishCapture(
        meetingID: meetingID,
        endedAt: "2026-09-22T11:00:00Z",
        durationSeconds: 3600,
        targetState: "captured",
        event: captureEvent("completed"),
    )

    let meeting = try #require(try await store.fetchMeeting(id: meetingID))
    #expect(meeting.state == "captured")
    #expect(meeting.captureEndedAt == "2026-09-22T11:00:00Z")
    #expect(meeting.durationSeconds == 3600)
    #expect(try await store.fetchStageEvents(meetingID: meetingID).map(\.event) == ["started", "completed"])
}

@Test func finishCaptureOnARowNoLongerRecordingIsStaleAndWritesNothing() async throws {
    let store = try makeStore()
    try await store.beginCapture(meeting: recordingMeeting(), event: captureEvent("started"))
    try await store.finishCapture(meetingID: meetingID, endedAt: "2026-09-22T11:00:00Z", durationSeconds: 1, targetState: "captured", event: captureEvent("completed"))

    await #expect(throws: StateStoreError.staleWrite(id: meetingID)) {
        try await store.finishCapture(
            meetingID: meetingID,
            endedAt: "2026-09-22T12:00:00Z",
            durationSeconds: 7200,
            targetState: "capture_failed",
            event: captureEvent("failed"),
        )
    }
    let meeting = try #require(try await store.fetchMeeting(id: meetingID))
    #expect(meeting.state == "captured")
    #expect(meeting.captureEndedAt == "2026-09-22T11:00:00Z")
    #expect(try await store.fetchStageEvents(meetingID: meetingID).map(\.event) == ["started", "completed"])
}

@Test func finishCaptureForAMissingRowIsMeetingNotFound() async throws {
    let store = try makeStore()
    await #expect(throws: StateStoreError.meetingNotFound(id: meetingID)) {
        try await store.finishCapture(meetingID: meetingID, endedAt: "x", durationSeconds: nil, targetState: "captured", event: captureEvent("completed"))
    }
}

@Test func finishCaptureRefusesAnEventForAnotherMeetingOrStage() async throws {
    let store = try makeStore()
    try await store.beginCapture(meeting: recordingMeeting(), event: captureEvent("started"))
    for event in [captureEvent("completed", stage: "transcribe"), captureEvent("completed", meeting: "01SOMEOTHERMEETINGID00000")] {
        await #expect(throws: StateStoreError.invalidCaptureEvent(id: meetingID)) {
            try await store.finishCapture(meetingID: meetingID, endedAt: "x", durationSeconds: nil, targetState: "captured", event: event)
        }
    }
    #expect(try await store.fetchMeeting(id: meetingID)?.state == "recording")
}

@Test func finishCaptureRollsTheStateBackWhenTheEventInsertFails() async throws {
    let store = try makeStore()
    try await store.beginCapture(meeting: recordingMeeting(), event: captureEvent("started"))
    let takenID = try #require(try await store.fetchStageEvents(meetingID: meetingID).first?.id)

    await #expect(throws: (any Error).self) {
        try await store.finishCapture(
            meetingID: meetingID,
            endedAt: "2026-09-22T11:00:00Z",
            durationSeconds: 3600,
            targetState: "captured",
            event: captureEvent("completed", id: takenID),
        )
    }
    let meeting = try #require(try await store.fetchMeeting(id: meetingID))
    #expect(meeting.state == "recording")
    #expect(meeting.captureEndedAt == nil)
    #expect(meeting.durationSeconds == nil)
}

@Test func localTimeZoneUsesTheStoredZoneAndFallsBackOtherwise() throws {
    let fallback = try #require(TimeZone(identifier: "Asia/Tokyo"))
    var meeting = recordingMeeting()
    #expect(meeting.localTimeZone(fallback: fallback).identifier == "America/Los_Angeles")
    meeting.captureTimeZone = nil
    #expect(meeting.localTimeZone(fallback: fallback) == fallback)
    meeting.captureTimeZone = "Not/AZone"
    #expect(meeting.localTimeZone(fallback: fallback) == fallback)
}
