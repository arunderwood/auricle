import CalendarInterface
@testable import Core
import Foundation
import GRDB
import Orchestrator
@testable import State
@testable import Summarize
import SummarizerInterface
import Telemetry
import Testing

// MARK: - Strategy stubs

/// Returns a fixed result or throws a fixed error, counts its calls so a
/// test can prove the summarizer was, or was never, reached, and keeps the
/// config of the last call so a test can see what the stage handed it.
/// `onSummarize` runs inside the call, before the result is returned, so a
/// test can change state the way something else running alongside the
/// summarizer would.
actor StageStubStrategy: SummarizerStrategy {
    private let result: Result<SummaryWithGrounding, any Error>
    private let onSummarize: (@Sendable () async throws -> Void)?
    private(set) var callCount = 0
    private(set) var lastConfig: SummarizerConfig?
    /// The glossary of the most recent call: what the stage decided to hand the summarizer.
    private(set) var receivedGlossary: Glossary?

    init(_ result: Result<SummaryWithGrounding, any Error>, onSummarize: (@Sendable () async throws -> Void)? = nil) {
        self.result = result
        self.onSummarize = onSummarize
    }

    func summarize(transcript _: CanonicalTranscript, glossary: Glossary, config: SummarizerConfig) async throws -> SummaryWithGrounding {
        callCount += 1
        lastConfig = config
        receivedGlossary = glossary
        try await onSummarize?()
        return try result.get()
    }
}

/// An error whose message could leak transcript text if the stage ever
/// recorded it.
struct StageLeakyError: Error, CustomStringConvertible {
    let secret: String
    var description: String {
        "leaked: \(secret)"
    }
}

// MARK: - Transcript fixture

let stageFirstText = "we should follow up with Ben about the café."
let stageSecondText = "lets ship it 🚀 on Friday."
let stageFirstLine = "Speaker_1: " + stageFirstText
let stageSecondLine = "Speaker_2: " + stageSecondText
let stageTranscriptText = stageFirstLine + "\n" + stageSecondLine

/// UTF-8 byte range of `needle` — the convention every pointer and utterance
/// uses, which diverges from a character range once the text has an accent or
/// an emoji.
func stageByteRange(of needle: String) -> (start: Int, end: Int) {
    guard let range = stageTranscriptText.range(of: needle) else {
        Issue.record("needle not found in transcript text")
        return (0, 0)
    }
    let start = stageTranscriptText.utf8.distance(from: stageTranscriptText.startIndex, to: range.lowerBound)
    return (start, start + needle.utf8.count)
}

func makeStageTranscript() -> CanonicalTranscript {
    let first = stageByteRange(of: stageFirstLine)
    let second = stageByteRange(of: stageSecondLine)
    return CanonicalTranscript(text: stageTranscriptText, utterances: [
        .init(speakerLabel: "Speaker_1", start: first.start, end: first.end),
        .init(speakerLabel: "Speaker_2", start: second.start, end: second.end),
    ])
}

let stageActionQuote = "we should follow up with Ben about the café."
let stageDecisionQuote = "lets ship it 🚀 on Friday."

func stageItem(_ text: String, quote: String, method: GroundingMethod = .citations) -> GroundedItem {
    let range = stageByteRange(of: quote)
    return GroundedItem(
        text: text,
        grounding: GroundingPointer(transcriptStart: range.start, transcriptEnd: range.end, sourceMethod: method),
    )
}

func makeStageGrounded(
    summary: String = "A short summary.",
    actionItems: [GroundedItem]? = nil,
    decisions: [GroundedItem]? = nil,
    method: GroundingMethod = .citations,
    dropCount: Int = 0,
) -> SummaryWithGrounding {
    SummaryWithGrounding(
        schemaVersion: 1,
        summary: summary,
        actionItems: actionItems ?? [stageItem("Follow up with Ben", quote: stageActionQuote, method: method)],
        decisions: decisions ?? [stageItem("Ship on Friday", quote: stageDecisionQuote, method: method)],
        groundingMethod: method,
        cost: SummarizerCost(inputTokens: 4200, outputTokens: 900, thinkingTokens: 1200, costUSD: 0.32),
        quoteValidationDropCount: dropCount,
    )
}

// MARK: - StageFixture

/// Noon UTC on 2026-04-28 is 05:00 in Pacific daylight time; the title test
/// pins the time zone, so the expected literal never depends on the machine.
let stageDefaultCaptureStartedAt = "2026-04-28T12:00:00Z"
let stageExpectedTitle = "Meeting at 2026-04-28T05:00 PDT"

struct StageAttributionFile: Encodable {
    let speakers: [String: String]
    let segmentOverrides: [String]

    enum CodingKeys: String, CodingKey {
        case speakers
        case segmentOverrides = "segment_overrides"
    }
}

/// A real in-memory store and a real `StageRunner`; only the summarizer
/// strategies are stubbed. The stage reads and writes the meeting's real cache
/// directory, so `meetingID` is a fresh ULID and `cleanUp()` removes only its
/// own subdirectory.
struct StageFixture {
    let meetingID = MeetingID.generate()
    let store: StateStore
    let runner: StageRunner
    let recorder: TelemetryRecorder

    /// `insertMeetingRow: false` leaves the store without a row for `meetingID`.
    /// `store` substitutes the default in-memory store, which does not enforce
    /// foreign keys the way the production openers do.
    init(
        captureStartedAt: String? = stageDefaultCaptureStartedAt,
        insertMeetingRow: Bool = true,
        store: StateStore? = nil,
    ) async throws {
        let resolvedStore = try store ?? StateStore.forTesting(writer: DatabaseQueue())
        self.store = resolvedStore
        runner = StageRunner(stateStore: resolvedStore, stageEventLogger: StageEventLogger(stateStore: resolvedStore))
        recorder = TelemetryRecorder(stateStore: resolvedStore)
        guard insertMeetingRow else { return }
        try await resolvedStore.insertMeeting(Meeting(
            id: meetingID.rawValue,
            state: "attributing",
            createdAt: "2026-04-28T09:00:00Z",
            updatedAt: "2026-04-28T09:00:00Z",
            captureStartedAt: captureStartedAt,
        ))
    }

    func cleanUp() {
        guard let directory = try? CacheArtifactWriter.cacheDirectory(for: meetingID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func plantTranscript(_ transcript: CanonicalTranscript = makeStageTranscript()) throws {
        try CacheArtifactWriter.write(transcript, for: meetingID, named: "transcript.json", schemaVersion: 1)
    }

    func plantAttribution(_ speakers: [String: String]) throws {
        try CacheArtifactWriter.write(
            StageAttributionFile(speakers: speakers, segmentOverrides: []),
            for: meetingID,
            named: "attribution.json",
            schemaVersion: 1,
        )
    }

    func glossaryURL() throws -> URL {
        try CacheArtifactWriter.cacheDirectory(for: meetingID).appendingPathComponent("glossary.json")
    }

    func summaryURL() throws -> URL {
        try CacheArtifactWriter.cacheDirectory(for: meetingID).appendingPathComponent("summary.json")
    }

    func calendarURL() throws -> URL {
        try CacheArtifactWriter.cacheDirectory(for: meetingID).appendingPathComponent("calendar.json")
    }

    /// `promptSetHash` replaces the stage's prompt-file hash resolution; nil
    /// runs the stage exactly as production does.
    func run(
        primary: StageStubStrategy,
        fallback: StageStubStrategy? = nil,
        glossary: Glossary = Glossary(),
        config: SummarizerConfig = SummarizerConfig(),
        calendarSource: (any CalendarSource)? = nil,
        publishAnyway: Bool = false,
        promptSetHash: (@Sendable (SummarizationMode) throws -> String)? = nil,
    ) async throws -> StageRunner.StageOutcome {
        let orchestrator = SummarizerOrchestrator(
            primary: primary,
            fallback: fallback ?? StageStubStrategy(.failure(SummarizerError.malformedResponse)),
        )
        if let promptSetHash {
            return try await SummarizeStage.run(
                meetingID: meetingID,
                stateStore: store,
                stageRunner: runner,
                telemetryRecorder: recorder,
                orchestrator: orchestrator,
                glossary: glossary,
                config: config,
                timeZone: #require(TimeZone(identifier: "America/Los_Angeles")),
                calendarSource: calendarSource,
                publishAnyway: publishAnyway,
                promptSetHash: promptSetHash,
            )
        }
        return try await SummarizeStage.run(
            meetingID: meetingID,
            stateStore: store,
            stageRunner: runner,
            telemetryRecorder: recorder,
            orchestrator: orchestrator,
            glossary: glossary,
            config: config,
            timeZone: #require(TimeZone(identifier: "America/Los_Angeles")),
            calendarSource: calendarSource,
            publishAnyway: publishAnyway,
        )
    }

    func readSummary() throws -> SummaryArtifact {
        try JSONDecoder().decode(SummaryArtifact.self, from: Data(contentsOf: summaryURL()))
    }

    /// `stage_events` in insertion order: `fetchStageEvents` orders by a
    /// second-resolution timestamp, which ties within a fast test.
    func events() async throws -> [StageEvent] {
        try await store.fetchStageEvents(meetingID: meetingID.rawValue).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    func state() async throws -> String? {
        try await store.fetchMeeting(id: meetingID.rawValue)?.state
    }
}

func stageMetadataObject(_ event: StageEvent) throws -> [String: Any] {
    let json = try #require(event.metadataJSON)
    return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

/// The shape every failure row must have: the meeting parked in
/// `summarization_failed`, no `summary.json`, exit code 2, a `failed` event
/// carrying the class.
func expectStageFailure(
    _ outcome: StageRunner.StageOutcome,
    fixture: StageFixture,
    errorClass expectedClass: String,
) async throws {
    guard case let .failed(targetState, errorClass, errorMessage, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .summarizationFailed)
    #expect(errorClass == expectedClass)
    #expect(SummarizeStage.exitCode(for: outcome) == 2)
    #expect(try await fixture.state() == "summarization_failed")
    let summaryURL = try fixture.summaryURL()
    #expect(!FileManager.default.fileExists(atPath: summaryURL.path))

    let events = try await fixture.events()
    #expect(events.map(\.event) == ["started", "failed"])
    let failedEvent = try #require(events.last)
    #expect(failedEvent.errorMessage == errorMessage)
    #expect(try stageMetadataObject(failedEvent)["error_class"] as? String == expectedClass)
}
