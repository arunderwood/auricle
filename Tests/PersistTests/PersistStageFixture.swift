import Core
import Foundation
import GRDB
import Orchestrator
@testable import Persist
@testable import State
import Telemetry
import Testing

func makeRunner(store: StateStore) -> StageRunner {
    StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store))
}

/// Noon UTC keeps the local calendar day identical to the UTC day across
/// every real-world timezone offset (-12...+14), so these literals — not a
/// recomputation of `PersistStage`'s own Calendar/TimeZone.current
/// algorithm — are the independently-known expected values: a shared
/// misunderstanding between this file and `PersistStage.localDateAndTime`
/// would go uncaught if both derived the same answer the same way.
let captureStartedAtString = "2026-04-28T12:00:00Z"
let expectedLocalDate = "2026-04-28"

/// Re-run instants sit weeks after the capture, at noon UTC for the same
/// zone-independence reason as the capture instant, so a re-run named by the
/// capture date instead of the re-run date can't pass by coincidence.
let firstRerunInstant = "2026-05-15T12:00:00Z"
let expectedFirstRerunDate = "2026-05-15"
let nextDayRerunInstant = "2026-05-16T12:00:00Z"
let expectedNextDayRerunDate = "2026-05-16"

func fixedTimeSource(at instant: String, zone: String = "UTC") throws -> PersistStage.TimeSource {
    let date = try #require(ISO8601UTC.date(from: instant))
    let timeZone = try #require(TimeZone(identifier: zone))
    return PersistStage.TimeSource(now: { date }, timeZone: timeZone)
}

func makeMeetingRow(
    id: String,
    vaultNotePath: String? = nil,
    captureStartedAt: String? = captureStartedAtString,
) -> Meeting {
    Meeting(
        id: id,
        state: "persisting",
        createdAt: "2026-04-28T09:00:00Z",
        updatedAt: "2026-04-28T09:00:00Z",
        captureStartedAt: captureStartedAt,
        vaultNotePath: vaultNotePath,
    )
}

let validSummaryJSON = """
{
  "title": "Tuesday Sync",
  "calendar_event_title": "Tuesday Sync",
  "attendees": ["[[Ben]]"],
  "self_wikilink": "[[Jordan]]",
  "needs_attribution": false,
  "needs_calendar_enrichment": false,
  "summary": "A summary paragraph mentioning [[Ben]].",
  "action_items": [{"text": "Follow up with Ben", "quote": "we should follow up"}],
  "decisions": [{"text": "Ship the feature", "quote": "lets ship it"}],
  "transcript_segments": [{"speaker": "[[Ben]]", "text": "Hello there"}]
}
"""

let validSummaryText = "A summary paragraph mentioning [[Ben]]."

/// `validSummaryJSON` with only its `summary` field replaced, so a test can
/// change what a re-run would render without touching anything else.
func summaryJSON(summary: String) -> String {
    validSummaryJSON.replacingOccurrences(of: validSummaryText, with: summary)
}

/// Plants the raw `summary.json` fixture directly (bypassing `AtomicWriter`,
/// per this file's `.swiftlint.yml` exclusion) — `PersistStage` only ever
/// reads this file, never writes it.
func writeSummaryJSON(_ json: String = validSummaryJSON, to cacheDirectory: URL) throws {
    try Data(json.utf8).write(to: cacheDirectory.appendingPathComponent("summary.json"))
}

struct TestFixture {
    let directory: URL
    let vaultPath: URL
    let meetingsSubdirURL: URL
    let cacheDirectory: URL
    let database: DatabaseQueue
    let store: StateStore
    let runner: StageRunner
}

func makeFixture(writeValidSummary: Bool = true) throws -> TestFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let vaultPath = directory.appendingPathComponent("vault")
    let meetingsSubdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: meetingsSubdirURL, withIntermediateDirectories: true)
    let cacheDirectory = directory.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    if writeValidSummary {
        try writeSummaryJSON(to: cacheDirectory)
    }
    let database = try DatabaseQueue()
    let store = try StateStore.forTesting(writer: database)
    return TestFixture(
        directory: directory,
        vaultPath: vaultPath,
        meetingsSubdirURL: meetingsSubdirURL,
        cacheDirectory: cacheDirectory,
        database: database,
        store: store,
        runner: makeRunner(store: store),
    )
}

/// Every test below calls `PersistStage.run` against the same fixture-owned
/// `cacheDirectory`/`stateStore`/`stageRunner` — only `meetingID`/(rarely)
/// `vaultPath`/`meetingsSubdir`/`clock` vary per scenario.
extension TestFixture {
    func run(
        meetingID: MeetingID,
        vaultPath: URL? = nil,
        meetingsSubdir: String = "Meetings",
        clock: PersistStage.TimeSource = PersistStage.TimeSource(),
    ) async throws -> StageRunner.StageOutcome {
        try await PersistStage.run(
            meetingID: meetingID,
            cacheDirectory: cacheDirectory,
            vaultPath: vaultPath ?? self.vaultPath,
            meetingsSubdir: meetingsSubdir,
            stateStore: store,
            stageRunner: runner,
            clock: clock,
        )
    }
}

func modificationDate(of url: URL) throws -> Date {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}

func setModificationDate(_ date: Date, of url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
}

/// Plants a well-formed auricle note for `meetingID` at `url`, creating any
/// missing parent folders. The body is fixed and differs from
/// `validSummaryJSON`'s rendering, so a planted note never counts as "unchanged".
func plantNote(meetingID: MeetingID, supersedes: String? = nil, at url: URL) throws {
    let markdown = FrontmatterRenderer.render(meeting: MeetingForFrontmatter(
        meetingID: meetingID,
        title: "Planted note",
        date: expectedLocalDate,
        attendees: [],
        schemaVersion: 1,
        supersedes: supersedes,
        needsAttribution: false,
        needsCalendarEnrichment: false,
        summary: "A planted note.",
        actionItems: [],
        decisions: [],
        transcriptSegments: [],
    ))
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(markdown.utf8).write(to: url)
}

func requireCompleted(_ outcome: StageRunner.StageOutcome) throws {
    guard case let .completed(targetState, _) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        throw CancellationError()
    }
    #expect(targetState == .published)
}

func readMeeting(_ fixture: TestFixture, _ meetingID: MeetingID) async throws -> Meeting {
    try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
}

func listedFiles(_ fixture: TestFixture) throws -> Set<String> {
    try Set(FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path))
}
