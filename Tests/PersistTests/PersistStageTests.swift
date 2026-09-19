import Core
import Foundation
import GRDB
import Orchestrator
@testable import Persist
@testable import State
import Telemetry
import Testing

private func makeStore() throws -> StateStore {
    try StateStore.forTesting(writer: DatabaseQueue())
}

private func makeRunner(store: StateStore) -> StageRunner {
    StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store))
}

private func makeTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Noon UTC keeps the local calendar day identical to the UTC day across
/// every real-world timezone offset (-12...+14), so these literals — not a
/// recomputation of `PersistStage`'s own Calendar/TimeZone.current
/// algorithm — are the independently-known expected values: a shared
/// misunderstanding between this file and `PersistStage.localDateAndTime`
/// would go uncaught if both derived the same answer the same way.
private let captureStartedAtString = "2026-04-28T12:00:00Z"
private let expectedLocalDate = "2026-04-28"

/// Re-run instants sit weeks after the capture, at noon UTC for the same
/// zone-independence reason as the capture instant, so a re-run named by the
/// capture date instead of the re-run date can't pass by coincidence.
private let firstRerunInstant = "2026-05-15T12:00:00Z"
private let expectedFirstRerunDate = "2026-05-15"
private let nextDayRerunInstant = "2026-05-16T12:00:00Z"
private let expectedNextDayRerunDate = "2026-05-16"

private func fixedTimeSource(at instant: String, zone: String = "UTC") throws -> PersistStage.TimeSource {
    let date = try #require(ISO8601UTC.date(from: instant))
    let timeZone = try #require(TimeZone(identifier: zone))
    return PersistStage.TimeSource(now: { date }, timeZone: timeZone)
}

private func makeMeetingRow(
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

private let validSummaryJSON = """
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

/// Plants the raw `summary.json` fixture directly (bypassing `AtomicWriter`,
/// per this file's `.swiftlint.yml` exclusion) — `PersistStage` only ever
/// reads this file, never writes it.
private func writeSummaryJSON(_ json: String = validSummaryJSON, to cacheDirectory: URL) throws {
    try Data(json.utf8).write(to: cacheDirectory.appendingPathComponent("summary.json"))
}

private struct TestFixture {
    let directory: URL
    let vaultPath: URL
    let meetingsSubdirURL: URL
    let cacheDirectory: URL
    let store: StateStore
    let runner: StageRunner
}

private func makeFixture(writeValidSummary: Bool = true) throws -> TestFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let vaultPath = directory.appendingPathComponent("vault")
    let meetingsSubdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: meetingsSubdirURL, withIntermediateDirectories: true)
    let cacheDirectory = directory.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    if writeValidSummary {
        try writeSummaryJSON(to: cacheDirectory)
    }
    let store = try makeStore()
    return TestFixture(
        directory: directory,
        vaultPath: vaultPath,
        meetingsSubdirURL: meetingsSubdirURL,
        cacheDirectory: cacheDirectory,
        store: store,
        runner: makeRunner(store: store),
    )
}

/// Every test below calls `PersistStage.run` against the same fixture-owned
/// `cacheDirectory`/`meetingsSubdir: "Meetings"`/`stateStore`/`stageRunner` —
/// only `meetingID`/`isRepublish`/(rarely) `vaultPath`/`clock` vary per scenario.
private extension TestFixture {
    func run(
        meetingID: MeetingID,
        isRepublish: Bool = false,
        vaultPath: URL? = nil,
        clock: PersistStage.TimeSource = PersistStage.TimeSource(),
    ) async throws -> StageRunner.StageOutcome {
        try await PersistStage.run(
            meetingID: meetingID,
            isRepublish: isRepublish,
            cacheDirectory: cacheDirectory,
            vaultPath: vaultPath ?? self.vaultPath,
            meetingsSubdir: "Meetings",
            stateStore: store,
            stageRunner: runner,
            clock: clock,
        )
    }
}

// MARK: - Fresh publish

@Test func freshPublishWritesNoteUpdatesVaultNotePathAndTransitionsToPublished() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    let outcome = try await fixture.run(meetingID: meetingID)

    guard case let .completed(targetState, metadataJSON) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .published)

    let localDate = expectedLocalDate
    let expectedURL = fixture.meetingsSubdirURL.appendingPathComponent("\(localDate)-tuesday-sync.md")
    #expect(FileManager.default.fileExists(atPath: expectedURL.path))

    // `SummaryArtifact`'s fields must actually reach the rendered note
    // through `PersistStage.frontmatterMeeting(_:supersedes:)`, not just
    // produce *a* file at the right path.
    let content = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(content.contains("\"Tuesday Sync\""))
    #expect(content.contains("[[Ben]]"))
    #expect(content.contains("A summary paragraph mentioning [[Ben]]."))
    #expect(content.contains("we should follow up"))
    #expect(content.contains("lets ship it"))

    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == expectedURL.path)
    #expect(meeting.state == "published")

    let metadata = try #require(metadataJSON)
    let object = try #require(JSONSerialization.jsonObject(with: Data(metadata.utf8)) as? [String: Any])
    #expect(Set(object.keys) == Set(["vault_note_path", "frontmatter_schema_version"]))
    #expect(object["vault_note_path"] as? String == expectedURL.path)
    #expect(object["frontmatter_schema_version"] as? Int == 1)

    let events = try await fixture.store.fetchStageEvents(meetingID: meetingID.rawValue)
    #expect(events.map(\.event) == ["started", "completed"])
    let completedEvent = try #require(events.last)
    #expect(completedEvent.metadataJSON == metadata)
}

// MARK: - Re-publish: original still exists

@Test func republishWithOriginalStillExistingWritesRerunSiblingAndPreservesOriginal() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let localDate = expectedLocalDate
    let originalURL = fixture.meetingsSubdirURL.appendingPathComponent("\(localDate)-tuesday-sync.md")
    let originalContent = Data("---\ntitle: \"Tuesday Sync\"\n---\n\nOriginal body\n".utf8)
    try originalContent.write(to: originalURL)
    let originalModifiedBefore = try #require(
        FileManager.default.attributesOfItem(atPath: originalURL.path)[.modificationDate] as? Date,
    )

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue, vaultNotePath: originalURL.path))

    let outcome = try await fixture.run(
        meetingID: meetingID,
        isRepublish: true,
        clock: fixedTimeSource(at: firstRerunInstant),
    )

    guard case let .completed(targetState, _) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .published)

    let expectedRerunURL = fixture.meetingsSubdirURL
        .appendingPathComponent("\(localDate)-tuesday-sync--rerun-\(expectedFirstRerunDate).md")
    #expect(FileManager.default.fileExists(atPath: expectedRerunURL.path))
    let rerunContent = try String(contentsOf: expectedRerunURL, encoding: .utf8)
    #expect(rerunContent.contains("supersedes"))
    #expect(rerunContent.contains("\"\(originalURL.lastPathComponent)\""))
    // Same field-flow-through check as the fresh-publish test, on the rerun
    // path's own `frontmatterMeeting(_:supersedes:)` call.
    #expect(rerunContent.contains("\"Tuesday Sync\""))
    #expect(rerunContent.contains("[[Ben]]"))
    #expect(rerunContent.contains("A summary paragraph mentioning [[Ben]]."))
    #expect(rerunContent.contains("we should follow up"))
    #expect(rerunContent.contains("lets ship it"))

    #expect(try Data(contentsOf: originalURL) == originalContent)
    let originalModifiedAfter = try FileManager.default.attributesOfItem(atPath: originalURL.path)[.modificationDate] as? Date
    #expect(originalModifiedAfter == originalModifiedBefore)

    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == expectedRerunURL.path)
}

private func modificationDate(of url: URL) throws -> Date {
    try #require(FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
}

private func requireCompleted(_ outcome: StageRunner.StageOutcome) throws {
    guard case let .completed(targetState, _) = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        throw CancellationError()
    }
    #expect(targetState == .published)
}

@Test func secondReattributeSameDayAppendsOrdinalTwoToTheRerunSuffix() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))
    let clock = try fixedTimeSource(at: firstRerunInstant)

    try await requireCompleted(fixture.run(meetingID: meetingID))
    let baseStem = "\(expectedLocalDate)-tuesday-sync"
    let originalURL = fixture.meetingsSubdirURL.appendingPathComponent("\(baseStem).md")
    let originalBytes = try Data(contentsOf: originalURL)
    let originalModified = try modificationDate(of: originalURL)

    try await requireCompleted(fixture.run(meetingID: meetingID, isRepublish: true, clock: clock))
    let firstRerunURL = fixture.meetingsSubdirURL.appendingPathComponent("\(baseStem)--rerun-\(expectedFirstRerunDate).md")
    #expect(FileManager.default.fileExists(atPath: firstRerunURL.path))
    let firstRerunBytes = try Data(contentsOf: firstRerunURL)
    let firstRerunModified = try modificationDate(of: firstRerunURL)

    try await requireCompleted(fixture.run(meetingID: meetingID, isRepublish: true, clock: clock))
    let secondRerunURL = fixture.meetingsSubdirURL.appendingPathComponent("\(baseStem)--rerun-\(expectedFirstRerunDate)-2.md")
    #expect(FileManager.default.fileExists(atPath: secondRerunURL.path))

    #expect(try Data(contentsOf: originalURL) == originalBytes)
    #expect(try modificationDate(of: originalURL) == originalModified)
    #expect(try Data(contentsOf: firstRerunURL) == firstRerunBytes)
    #expect(try modificationDate(of: firstRerunURL) == firstRerunModified)

    let secondRerunContent = try String(contentsOf: secondRerunURL, encoding: .utf8)
    #expect(secondRerunContent.contains("\"\(firstRerunURL.lastPathComponent)\""))
    #expect(!secondRerunContent.contains("\"\(originalURL.lastPathComponent)\""))

    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == secondRerunURL.path)

    let writtenFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path)
    #expect(Set(writtenFiles) == Set([
        originalURL.lastPathComponent,
        firstRerunURL.lastPathComponent,
        secondRerunURL.lastPathComponent,
    ]))
}

@Test func rerunOnALaterDayNamesTheBaseStemWithTheNewDateInsteadOfNestingSuffixes() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    try await requireCompleted(fixture.run(meetingID: meetingID))
    try await requireCompleted(fixture.run(
        meetingID: meetingID,
        isRepublish: true,
        clock: fixedTimeSource(at: firstRerunInstant),
    ))
    try await requireCompleted(fixture.run(
        meetingID: meetingID,
        isRepublish: true,
        clock: fixedTimeSource(at: nextDayRerunInstant),
    ))

    let baseStem = "\(expectedLocalDate)-tuesday-sync"
    let firstRerunName = "\(baseStem)--rerun-\(expectedFirstRerunDate).md"
    let nextDayName = "\(baseStem)--rerun-\(expectedNextDayRerunDate).md"
    let writtenFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path)
    #expect(Set(writtenFiles) == Set(["\(baseStem).md", firstRerunName, nextDayName]))

    let nextDayURL = fixture.meetingsSubdirURL.appendingPathComponent(nextDayName)
    let nextDayContent = try String(contentsOf: nextDayURL, encoding: .utf8)
    #expect(nextDayContent.contains("\"\(firstRerunName)\""))

    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == nextDayURL.path)
}

/// Mirrors `VaultWriterTests.swift`'s
/// `throwsCollisionRetriesExhaustedWhenEveryOrdinalUpToTheCapCollides`:
/// references `PersistStage.maxRerunOrdinal` directly (via `@testable
/// import`) rather than a hardcoded duplicate that could drift from the real
/// cap.
@Test func republishRerunLoopFailsWithRerunRetriesExhaustedWhenEveryOrdinalUpToTheCapCollides() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let stem = "\(expectedLocalDate)-tuesday-sync"
    let originalURL = fixture.meetingsSubdirURL.appendingPathComponent("\(stem).md")
    try Data("original".utf8).write(to: originalURL)
    for ordinal in 1 ... PersistStage.maxRerunOrdinal {
        let suffix = ordinal >= 2 ? "-\(ordinal)" : ""
        let candidateURL = fixture.meetingsSubdirURL.appendingPathComponent("\(stem)--rerun-\(expectedFirstRerunDate)\(suffix).md")
        try Data("rerun".utf8).write(to: candidateURL)
    }

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue, vaultNotePath: originalURL.path))

    let outcome = try await fixture.run(
        meetingID: meetingID,
        isRepublish: true,
        clock: fixedTimeSource(at: firstRerunInstant),
    )

    guard case let .failed(targetState, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .persistFailed)
    #expect(errorClass == "rerun_retries_exhausted")

    // The failed rerun attempt must not disturb the still-valid pointer to
    // the original note.
    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == originalURL.path)
}

// MARK: - Re-publish: fallback to standard publish

@Test func republishFallsBackToStandardPublishWhenOriginalFileWasDeleted() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let danglingPath = fixture.meetingsSubdirURL.appendingPathComponent("deleted-by-user.md").path

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue, vaultNotePath: danglingPath))

    let outcome = try await fixture.run(meetingID: meetingID, isRepublish: true)

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }

    let localDate = expectedLocalDate
    let expectedURL = fixture.meetingsSubdirURL.appendingPathComponent("\(localDate)-tuesday-sync.md")
    #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    let content = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(!content.contains("supersedes"))

    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == expectedURL.path)
}

@Test func republishFallsBackToStandardPublishWhenNeverPublished() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue, vaultNotePath: nil))

    let outcome = try await fixture.run(meetingID: meetingID, isRepublish: true)

    guard case .completed = outcome else {
        Issue.record("expected .completed outcome, got \(outcome)")
        return
    }

    let localDate = expectedLocalDate
    let expectedURL = fixture.meetingsSubdirURL.appendingPathComponent("\(localDate)-tuesday-sync.md")
    #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    let content = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(!content.contains("supersedes"))
}

// MARK: - Time zone

/// 03:30Z on the 28th is 20:30 on the 27th in Los Angeles (UTC-7 in April),
/// so the filename's date and time and the frontmatter `date` all differ from
/// what UTC gives. Only a machine zone that is also at UTC-7 could satisfy
/// them without honoring the injected zone.
@Test func captureDateAndTimeAreRenderedInTheInjectedTimeZone() async throws {
    let fixture = try makeFixture(writeValidSummary: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try writeSummaryJSON(
        """
        {
          "title": "Meeting at 2026-04-27T20:30 PDT",
          "calendar_event_title": null,
          "attendees": [],
          "self_wikilink": null,
          "needs_attribution": false,
          "needs_calendar_enrichment": true,
          "summary": "A summary paragraph.",
          "action_items": [],
          "decisions": [],
          "transcript_segments": []
        }
        """,
        to: fixture.cacheDirectory,
    )
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue, captureStartedAt: "2026-04-28T03:30:00Z"))

    try await requireCompleted(fixture.run(
        meetingID: meetingID,
        clock: fixedTimeSource(at: firstRerunInstant, zone: "America/Los_Angeles"),
    ))

    let expectedURL = fixture.meetingsSubdirURL.appendingPathComponent("2026-04-27-meeting-at-2030.md")
    #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    let content = try String(contentsOf: expectedURL, encoding: .utf8)
    #expect(content.contains("date: 2026-04-27"))
}

// MARK: - summary.json failures

@Test func summaryArtifactMissingFailsWithoutAttemptingAVaultWrite() async throws {
    let fixture = try makeFixture(writeValidSummary: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    let outcome = try await fixture.run(meetingID: meetingID)

    guard case let .failed(targetState, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .persistFailed)
    #expect(errorClass == "summary_artifact_unreadable")

    let writtenFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path)
    #expect(writtenFiles.isEmpty)

    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == nil)

    let events = try await fixture.store.fetchStageEvents(meetingID: meetingID.rawValue)
    #expect(events.map(\.event) == ["started", "failed"])
    let failedEvent = try #require(events.last)
    #expect(failedEvent.metadataJSON?.contains("\"error_class\":\"summary_artifact_unreadable\"") == true)
}

@Test func summaryArtifactMalformedFailsWithUndecodableErrorClass() async throws {
    let fixture = try makeFixture(writeValidSummary: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try writeSummaryJSON("{ this is not valid json", to: fixture.cacheDirectory)

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    let outcome = try await fixture.run(meetingID: meetingID)

    guard case let .failed(targetState, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .persistFailed)
    #expect(errorClass == "summary_artifact_undecodable")

    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == nil)
}

// MARK: - Meeting row failures

@Test func missingCaptureStartedAtFailsWithMissingCaptureStartedAtErrorClass() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue, captureStartedAt: nil))

    let outcome = try await fixture.run(meetingID: meetingID)

    guard case let .failed(targetState, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .persistFailed)
    #expect(errorClass == "missing_capture_started_at")

    let writtenFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path)
    #expect(writtenFiles.isEmpty)
}

/// `stateStore.fetchMeeting` returning `nil` inside `work` is the I/O
/// matrix's own "Meeting row not found" row — implemented defensively in
/// `PersistStage.publish` for exactly that case. It is not independently
/// reachable through this public entry point, though: `StageRunner.run`'s
/// own Txn A (unmodified Epic-1 infrastructure this story composes, never
/// reimplements) writes a `stage_events` row for `meetingID` before `work`
/// ever runs, and `stage_events.meeting_id` carries a foreign key against
/// `meetings.id` — a truly-absent row fails that insert with a foreign-key
/// `DatabaseError` first, so `publish`'s own guard is never reached for this
/// input. This test documents that actual, real behavior rather than the
/// matrix's `.failed(...)` framing.
@Test func runThrowsDatabaseErrorWhenTheMeetingRowNeverExistedBecauseTxnARequiresItFirst() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate() // Deliberately never inserted.

    await #expect(throws: DatabaseError.self) {
        try await fixture.run(meetingID: meetingID)
    }
}

// MARK: - VaultWriter failure propagation

@Test func vaultWriteFailureFoldsIntoVaultWriteFailedErrorClass() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let missingVaultPath = fixture.directory.appendingPathComponent("does-not-exist")

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    let outcome = try await fixture.run(meetingID: meetingID, vaultPath: missingVaultPath)

    guard case let .failed(targetState, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        return
    }
    #expect(targetState == .persistFailed)
    #expect(errorClass == "vault_write_failed")

    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == nil)

    let events = try await fixture.store.fetchStageEvents(meetingID: meetingID.rawValue)
    #expect(events.map(\.event) == ["started", "failed"])
    let failedEvent = try #require(events.last)
    #expect(failedEvent.metadataJSON?.contains("\"error_class\":\"vault_write_failed\"") == true)
}

// MARK: - Filename inputs and error-class folds

// Every `PersistStage` scenario runs on the private fixtures at the top of
// this file, so the file stays whole instead of splitting. Only this file
// is exempt from the 600-line limit.
// swiftlint:disable file_length

/// `title` and `calendar_event_title` are separate parameters, and so are the
/// two fields the attendee slug reads, because each feeds a different
/// consumer: the filename slug chain reads the calendar title, attendees and
/// self wikilink, while the frontmatter reads `title`. A test can only tell
/// which one `PersistStage` wired to which consumer if the values differ.
private func filenameInputSummaryJSON(
    title: String,
    calendarEventTitle: String?,
    attendees: [String] = [],
    selfWikilink: String? = nil,
) -> String {
    let quote = { (value: String) in "\"\(value)\"" }
    return """
    {
      "title": \(quote(title)),
      "calendar_event_title": \(calendarEventTitle.map(quote) ?? "null"),
      "attendees": [\(attendees.map(quote).joined(separator: ","))],
      "self_wikilink": \(selfWikilink.map(quote) ?? "null"),
      "needs_attribution": false,
      "needs_calendar_enrichment": false,
      "summary": "A summary paragraph.",
      "action_items": [],
      "decisions": [],
      "transcript_segments": []
    }
    """
}

private func requirePersistFailed(_ outcome: StageRunner.StageOutcome, errorClass expected: String) throws -> String? {
    guard case let .failed(targetState, errorClass, errorMessage, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        throw CancellationError()
    }
    #expect(targetState == .persistFailed)
    #expect(errorClass == expected)
    return errorMessage
}

@Test func noCalendarTitleAndNoAttendeesNamesTheNoteAfterTheLocalCaptureTime() async throws {
    let fixture = try makeFixture(writeValidSummary: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try writeSummaryJSON(
        filenameInputSummaryJSON(title: "Meeting at 2026-04-28T12:00 UTC", calendarEventTitle: nil),
        to: fixture.cacheDirectory,
    )
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: captureStartedAtString)))

    let writtenFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path)
    #expect(writtenFiles == ["\(expectedLocalDate)-meeting-at-1200.md"])
}

@Test func noCalendarTitleNamesTheNoteAfterTheAttendeesOtherThanSelf() async throws {
    let fixture = try makeFixture(writeValidSummary: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try writeSummaryJSON(
        filenameInputSummaryJSON(
            title: "Ben and Jordan catch-up",
            calendarEventTitle: nil,
            attendees: ["[[Ben]]", "[[Jordan]]"],
            selfWikilink: "[[Jordan]]",
        ),
        to: fixture.cacheDirectory,
    )
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    try await requireCompleted(fixture.run(meetingID: meetingID))

    let writtenFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path)
    #expect(writtenFiles == ["\(expectedLocalDate)-with-ben.md"])
}

@Test func calendarTitleFeedsTheFilenameSlugWhileTitleFeedsTheFrontmatter() async throws {
    let fixture = try makeFixture(writeValidSummary: false)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    try writeSummaryJSON(
        filenameInputSummaryJSON(title: "Renamed Sync", calendarEventTitle: "Tuesday Sync"),
        to: fixture.cacheDirectory,
    )
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    try await requireCompleted(fixture.run(meetingID: meetingID))

    let writtenFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path)
    #expect(writtenFiles == ["\(expectedLocalDate)-tuesday-sync.md"])
    let content = try String(contentsOf: fixture.meetingsSubdirURL.appendingPathComponent(writtenFiles[0]), encoding: .utf8)
    #expect(content.contains("title: \"Renamed Sync\""))
    #expect(!content.contains("Tuesday Sync"))
}

/// A directory (not a file) at the resolved temp path makes `AtomicWriter`'s
/// own `createFile` fail with no race involved, so the failure comes from the
/// `AtomicWriter.WriteError` branch of the fold rather than `VaultWriter`'s.
@Test func atomicWriterFailureFoldsIntoVaultWriteFailedErrorClass() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let targetURL = fixture.meetingsSubdirURL.appendingPathComponent("\(expectedLocalDate)-tuesday-sync.md")
    try FileManager.default.createDirectory(at: AtomicWriter.temporaryURL(for: targetURL), withIntermediateDirectories: true)
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    let outcome = try await fixture.run(meetingID: meetingID)

    let errorMessage = try requirePersistFailed(outcome, errorClass: "vault_write_failed")
    #expect(errorMessage?.contains("createTemporaryFileFailed") == true)
    #expect(!FileManager.default.fileExists(atPath: targetURL.path))
    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == nil)
}

/// Mirrors `VaultWriterTests.swift`'s
/// `throwsCollisionRetriesExhaustedWhenEveryOrdinalUpToTheCapCollides`, one
/// layer up: the same exhaustion must reach the stage as a `.failed` outcome.
@Test func collisionRetriesExhaustedFoldsIntoVaultWriteFailedErrorClass() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let stem = "\(expectedLocalDate)-tuesday-sync"
    for ordinal in 1 ... VaultWriter.maxCollisionOrdinal {
        let suffix = ordinal >= 2 ? "-\(ordinal)" : ""
        try Data().write(to: fixture.meetingsSubdirURL.appendingPathComponent("\(stem)\(suffix).md"))
    }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    let outcome = try await fixture.run(meetingID: meetingID)

    let errorMessage = try requirePersistFailed(outcome, errorClass: "vault_write_failed")
    #expect(errorMessage?.contains("collisionRetriesExhausted") == true)
    let writtenFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.meetingsSubdirURL.path)
    #expect(writtenFiles.count == VaultWriter.maxCollisionOrdinal)
    let meeting = try #require(try await fixture.store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == nil)
}

/// The trigger rejects only the `vault_note_path` write `publish` makes after
/// the vault write, so `StageRunner`'s own transaction that records the
/// failure still goes through.
@Test func aStateStoreFailureInsideThePublishFoldsIntoPersistUnexpectedErrorClass() async throws {
    let queue = try DatabaseQueue()
    let store = try StateStore.forTesting(writer: queue)
    let base = try makeFixture()
    defer { try? FileManager.default.removeItem(at: base.directory) }
    let fixture = TestFixture(
        directory: base.directory,
        vaultPath: base.vaultPath,
        meetingsSubdirURL: base.meetingsSubdirURL,
        cacheDirectory: base.cacheDirectory,
        store: store,
        runner: makeRunner(store: store),
    )
    try await queue.write {
        try $0.execute(sql: """
        CREATE TRIGGER reject_vault_note_path BEFORE UPDATE ON meetings
        WHEN NEW.vault_note_path IS NOT NULL
        BEGIN SELECT RAISE(ABORT, 'rejected'); END
        """)
    }
    let meetingID = MeetingID.generate()
    try await store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    let outcome = try await fixture.run(meetingID: meetingID)

    let errorMessage = try requirePersistFailed(outcome, errorClass: "persist_unexpected_error")
    #expect(errorMessage?.contains("rejected") == true)
    let meeting = try #require(try await store.fetchMeeting(id: meetingID.rawValue))
    #expect(meeting.vaultNotePath == nil)
    #expect(meeting.state == "persist_failed")
}
