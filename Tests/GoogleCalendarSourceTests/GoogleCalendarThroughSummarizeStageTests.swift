import CalendarInterface
import Core
import Foundation
@testable import GoogleCalendarSource
import GRDB
import Orchestrator
@testable import State
import Summarize
import SummarizerInterface
import Telemetry
import Testing

// The real `GoogleCalendarSource`, over a URLProtocol stub and a throwaway
// Keychain service, driven by the real `SummarizeStage`. Nothing here reaches
// the network or the maintainer's Keychain item.

// 2026-04-28T12:00:00Z, the moment the recording began.
private let captureStart = Date(timeIntervalSince1970: 1_777_377_600)
private let captureStartedAt = "2026-04-28T12:00:00Z"
private let privateEmail = "ada.private@example.com"

private actor RecordingSummarizer: SummarizerStrategy {
    private(set) var attendeeNames: [String]?

    func summarize(transcript _: CanonicalTranscript, glossary _: Glossary, config: SummarizerConfig) async throws -> SummaryWithGrounding {
        attendeeNames = config.attendeeNames
        return SummaryWithGrounding(
            schemaVersion: 1,
            summary: "A short summary.",
            actionItems: [],
            decisions: [],
            groundingMethod: .substring,
            cost: SummarizerCost(inputTokens: 1, outputTokens: 1, thinkingTokens: 0, costUSD: 0),
            quoteValidationDropCount: 0,
        )
    }
}

private final class BrowserOpenCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private func minutesAfterCapture(_ minutes: Double) -> Date {
    captureStart.addingTimeInterval(minutes * 60)
}

private struct StageRun {
    let meetingID = MeetingID.generate()
    let store: StateStore
    let summarizer = RecordingSummarizer()

    init() async throws {
        store = try StateStore.forTesting(writer: DatabaseQueue())
        try await store.insertMeeting(Meeting(
            id: meetingID.rawValue,
            state: "attributing",
            createdAt: "2026-04-28T09:00:00Z",
            updatedAt: "2026-04-28T09:00:00Z",
            captureStartedAt: captureStartedAt,
        ))
        let text = "Speaker_1: hello there."
        let transcript = CanonicalTranscript(
            text: text,
            utterances: [.init(speakerLabel: "Speaker_1", start: 0, end: text.utf8.count)],
        )
        try CacheArtifactWriter.write(transcript, for: meetingID, named: "transcript.json", schemaVersion: 1)
    }

    func cleanUp() {
        guard let directory = try? CacheArtifactWriter.cacheDirectory(for: meetingID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func run(with source: any CalendarSource) async throws -> StageRunner.StageOutcome {
        try await SummarizeStage.run(
            meetingID: meetingID,
            stateStore: store,
            stageRunner: StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store)),
            telemetryRecorder: TelemetryRecorder(stateStore: store),
            orchestrator: SummarizerOrchestrator(primary: summarizer),
            glossary: Glossary(),
            config: SummarizerConfig(),
            calendarSource: source,
        )
    }

    private func artifactURL(_ name: String) throws -> URL {
        try CacheArtifactWriter.cacheDirectory(for: meetingID).appendingPathComponent(name)
    }

    func readSummary() throws -> SummaryArtifact {
        try JSONDecoder().decode(SummaryArtifact.self, from: Data(contentsOf: artifactURL("summary.json")))
    }

    func readCalendar() throws -> CalendarArtifact {
        try JSONDecoder().decode(CalendarArtifact.self, from: Data(contentsOf: artifactURL("calendar.json")))
    }

    func artifactText(_ name: String) throws -> String {
        try String(contentsOf: artifactURL(name), encoding: .utf8)
    }
}

@Test func aMatchedEventEnrichesTheSummaryTheMeetingRowAndTheSummarizersAttendees() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(
                id: "evt123",
                summary: "Weekly Sync",
                start: minutesAfterCapture(-2),
                end: minutesAfterCapture(58),
                attendees: [
                    ["email": privateEmail, "displayName": "Ada Lovelace", "self": true, "responseStatus": "accepted"],
                    ["email": "ben.private@example.com", "displayName": "Ben Ng", "responseStatus": "needsAction"],
                ],
            ),
        ])
    })
    defer { harness.cleanup() }
    let run = try await StageRun()
    defer { run.cleanUp() }

    let outcome = try await run.run(with: harness.source)

    guard case .completed = outcome else {
        Issue.record("expected the stage to complete, got \(outcome)")
        return
    }
    let query = try #require(harness.stub.eventRequests.first).query
    #expect(harness.stub.eventRequests.count == 1)
    #expect(query["timeMin"] == ISO8601UTC.string(from: captureStart.addingTimeInterval(-1)))

    let summary = try run.readSummary()
    #expect(summary.title == "Weekly Sync")
    #expect(summary.calendarEventTitle == "Weekly Sync")
    #expect(summary.needsCalendarEnrichment == false)
    #expect(summary.attendees == ["[[Ada Lovelace]]", "[[Ben Ng]]"])
    #expect(summary.selfWikilink == "[[Ada Lovelace]]")

    let calendar = try run.readCalendar()
    #expect(calendar.degraded == false)
    #expect(calendar.event?.eventID == "google:evt123")

    let row = try #require(try await run.store.fetchMeeting(id: run.meetingID.rawValue))
    #expect(row.title == "Weekly Sync")
    #expect(row.calendarEventID == "google:evt123")

    #expect(await run.summarizer.attendeeNames == ["Ada Lovelace", "Ben Ng"])
    #expect(try !run.artifactText("calendar.json").contains(privateEmail))
    #expect(try !run.artifactText("summary.json").contains(privateEmail))
    #expect(harness.stub.tokenRequests.count == 1)
}

@Test func aRecordingStartedAheadOfItsMeetingIsEnrichedWithThatMeetingNotTheOneStillRunning() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "earlier", summary: "Earlier Meeting", start: minutesAfterCapture(-58), end: minutesAfterCapture(2)),
            eventJSON(id: "joined", summary: "Joined Meeting", start: minutesAfterCapture(2), end: minutesAfterCapture(62)),
        ])
    })
    defer { harness.cleanup() }
    let run = try await StageRun()
    defer { run.cleanUp() }

    _ = try await run.run(with: harness.source)

    #expect(try run.readSummary().title == "Joined Meeting")
    #expect(try run.readCalendar().event?.eventID == "google:joined")
}

@Test func aDeclinedEventLeavesTheRunUnenrichedAndTagsTheSummary() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(
                id: "declined",
                summary: "Declined Meeting",
                start: minutesAfterCapture(-5),
                end: minutesAfterCapture(25),
                attendees: [["email": privateEmail, "self": true, "responseStatus": "declined"]],
            ),
        ])
    })
    defer { harness.cleanup() }
    let run = try await StageRun()
    defer { run.cleanUp() }

    let outcome = try await run.run(with: harness.source)

    guard case .completed = outcome else {
        Issue.record("expected the stage to complete, got \(outcome)")
        return
    }
    let summary = try run.readSummary()
    #expect(summary.needsCalendarEnrichment == true)
    #expect(summary.calendarEventTitle == nil)
    #expect(try run.readCalendar().degraded == true)
    #expect(try await run.store.fetchMeeting(id: run.meetingID.rawValue)?.calendarEventID == nil)
}

@Test func anUnauthorizedSourceDegradesTheRunWithoutOpeningABrowser() async throws {
    let opens = BrowserOpenCount()
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { _ in opens.increment() },
    )
    defer { harness.cleanup() }
    let run = try await StageRun()
    defer { run.cleanUp() }

    let outcome = try await run.run(with: harness.source)

    guard case .completed = outcome else {
        Issue.record("expected the stage to complete, got \(outcome)")
        return
    }
    #expect(try run.readSummary().needsCalendarEnrichment == true)
    #expect(try run.readCalendar().degraded == true)
    #expect(opens.value == 0)
    #expect(harness.stub.eventRequests.isEmpty)
}

@Test func anUnreachableCalendarDegradesTheRunInsteadOfFailingTheStage() async throws {
    let harness = try SourceHarness(events: { _, _ in .text(503, "unavailable") })
    defer { harness.cleanup() }
    let run = try await StageRun()
    defer { run.cleanUp() }

    let outcome = try await run.run(with: harness.source)

    guard case .completed = outcome else {
        Issue.record("expected the stage to complete, got \(outcome)")
        return
    }
    #expect(try run.readSummary().needsCalendarEnrichment == true)
}
