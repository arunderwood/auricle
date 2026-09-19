import CalendarInterface
@testable import Core
import Foundation
import GRDB
import Orchestrator
@testable import State
@testable import Summarize
import SummarizerInterface
import Testing

// MARK: - Bookkeeping after the paid call

// Once the summarizer has answered and `summary.json` is on disk, a failing
// telemetry or meeting-row write must not turn the run into
// `summarization_failed`: a retry would pay for the same summary again.

@Test func aTelemetryWriteFailureAfterTheSummaryIsWrittenStillCompletesTheStage() async throws {
    let queue = try DatabaseQueue()
    let fixture = try await StageFixture(store: StateStore.forTesting(writer: queue))
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    let primary = StageStubStrategy(.success(makeStageGrounded())) {
        try await queue.write { try $0.execute(sql: "DROP TABLE telemetry") }
    }

    let outcome = try await fixture.run(primary: primary)

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(try fixture.readSummary().summary == "A short summary.")
    #expect(try await fixture.state() == "persisting")
    #expect(try await fixture.events().map(\.event) == ["started", "completed"])
    #expect(SummarizeStage.exitCode(for: outcome) == 0)
}

@Test func aMeetingRowRefreshFailureAfterTheSummaryIsWrittenStillCompletesTheStage() async throws {
    let queue = try DatabaseQueue()
    let fixture = try await StageFixture(store: StateStore.forTesting(writer: queue))
    defer { fixture.cleanUp() }
    try fixture.plantTranscript()
    try await queue.write {
        try $0.execute(sql: """
        CREATE TRIGGER reject_calendar_event_id BEFORE UPDATE ON meetings
        WHEN NEW.calendar_event_id IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'rejected'); END
        """)
    }
    let start = try #require(ISO8601UTC.date(from: stageDefaultCaptureStartedAt))
    let event = CalendarEvent(id: "google:evt123", title: "Weekly Sync", start: start, end: start.addingTimeInterval(3600), attendees: [])
    let outcome = try await fixture.run(
        primary: StageStubStrategy(.success(makeStageGrounded())),
        calendarSource: StubCalendarSource(.success(event)),
    )

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(try fixture.readSummary().title == "Weekly Sync")
    let row = try #require(try await fixture.store.fetchMeeting(id: fixture.meetingID.rawValue))
    #expect(row.calendarEventID == nil)
    #expect(row.state == "persisting")
    let telemetry = try #require(try await fixture.store.fetchTelemetry(meetingID: fixture.meetingID.rawValue))
    #expect(telemetry.costUSD == 0.32)
}
