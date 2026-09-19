import Core
import Foundation
import GRDB
import Orchestrator
@testable import Persist
@testable import State
import Telemetry
import Testing

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
