import Core
import Foundation
import GRDB
import Orchestrator
@testable import Persist
@testable import State
import Telemetry
import Testing

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

@Test func secondChangedRepublishSameDayAppendsOrdinalTwoToTheRerunSuffix() async throws {
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

    try writeSummaryJSON(summaryJSON(summary: "Second summary."), to: fixture.cacheDirectory)
    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))
    let firstRerunURL = fixture.meetingsSubdirURL.appendingPathComponent("\(baseStem)--rerun-\(expectedFirstRerunDate).md")
    #expect(FileManager.default.fileExists(atPath: firstRerunURL.path))
    let firstRerunBytes = try Data(contentsOf: firstRerunURL)
    let firstRerunModified = try modificationDate(of: firstRerunURL)

    try writeSummaryJSON(summaryJSON(summary: "Third summary."), to: fixture.cacheDirectory)
    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))
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
    try writeSummaryJSON(summaryJSON(summary: "Second summary."), to: fixture.cacheDirectory)
    try await requireCompleted(fixture.run(
        meetingID: meetingID,
        clock: fixedTimeSource(at: firstRerunInstant),
    ))
    try writeSummaryJSON(summaryJSON(summary: "Third summary."), to: fixture.cacheDirectory)
    try await requireCompleted(fixture.run(
        meetingID: meetingID,
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

// MARK: - Re-running the stage reuses identical output

@Test func runningTwiceOnUnchangedInputWritesNothingTheSecondTime() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))
    let clock = try fixedTimeSource(at: firstRerunInstant)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))
    let noteURL = fixture.meetingsSubdirURL.appendingPathComponent("\(expectedLocalDate)-tuesday-sync.md")
    let noteBytes = try Data(contentsOf: noteURL)
    let noteModified = try modificationDate(of: noteURL)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))

    #expect(try listedFiles(fixture) == [noteURL.lastPathComponent])
    #expect(try Data(contentsOf: noteURL) == noteBytes)
    #expect(try modificationDate(of: noteURL) == noteModified)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == noteURL.path)
}

@Test func aWriteTheRowNeverRecordedIsReusedInsteadOfDuplicatedWithOrdinalTwo() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    try await requireCompleted(fixture.run(meetingID: meetingID))
    let noteURL = fixture.meetingsSubdirURL.appendingPathComponent("\(expectedLocalDate)-tuesday-sync.md")
    let noteBytes = try Data(contentsOf: noteURL)
    let noteModified = try modificationDate(of: noteURL)
    try await fixture.database.write { db in
        try db.execute(sql: "UPDATE meetings SET vault_note_path = NULL WHERE id = ?", arguments: [meetingID.rawValue])
    }

    try await requireCompleted(fixture.run(meetingID: meetingID))

    #expect(try listedFiles(fixture) == [noteURL.lastPathComponent])
    #expect(try Data(contentsOf: noteURL) == noteBytes)
    #expect(try modificationDate(of: noteURL) == noteModified)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == noteURL.path)
}

@Test func aChangedSummaryWritesASupersedingRerunAndLeavesTheOriginalUntouched() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    try await requireCompleted(fixture.run(meetingID: meetingID))
    let originalURL = fixture.meetingsSubdirURL.appendingPathComponent("\(expectedLocalDate)-tuesday-sync.md")
    let originalBytes = try Data(contentsOf: originalURL)
    let originalModified = try modificationDate(of: originalURL)

    try writeSummaryJSON(summaryJSON(summary: "A revised summary."), to: fixture.cacheDirectory)
    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    let rerunURL = fixture.meetingsSubdirURL
        .appendingPathComponent("\(expectedLocalDate)-tuesday-sync--rerun-\(expectedFirstRerunDate).md")
    #expect(try listedFiles(fixture) == [originalURL.lastPathComponent, rerunURL.lastPathComponent])
    let rerunContent = try String(contentsOf: rerunURL, encoding: .utf8)
    #expect(rerunContent.contains("supersedes: \"\(originalURL.lastPathComponent)\""))
    #expect(rerunContent.contains("A revised summary."))
    #expect(try Data(contentsOf: originalURL) == originalBytes)
    #expect(try modificationDate(of: originalURL) == originalModified)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == rerunURL.path)
}

@Test func aRerunUnchangedSinceItsPublishIsNotRepublishedAgain() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))
    let clock = try fixedTimeSource(at: firstRerunInstant)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))
    try writeSummaryJSON(summaryJSON(summary: "A revised summary."), to: fixture.cacheDirectory)
    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))
    let filesAfterRerun = try listedFiles(fixture)
    let storedPath = try #require(try await readMeeting(fixture, meetingID).vaultNotePath)
    let storedBytes = try Data(contentsOf: URL(fileURLWithPath: storedPath))

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))

    #expect(try listedFiles(fixture) == filesAfterRerun)
    #expect(try Data(contentsOf: URL(fileURLWithPath: storedPath)) == storedBytes)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == storedPath)
}

/// Fails the `vault_note_path` update the way a crash after the vault write
/// would: the note is on disk, the row never learns about it.
private func failVaultNotePathUpdates(_ fixture: TestFixture) throws {
    try fixture.database.write { db in
        try db.execute(sql: """
        CREATE TRIGGER fail_vault_note_path_update
        BEFORE UPDATE ON meetings
        WHEN NEW.vault_note_path IS NOT OLD.vault_note_path
        BEGIN SELECT RAISE(ABORT, 'vault_note_path update refused'); END
        """)
    }
}

private func allowVaultNotePathUpdates(_ fixture: TestFixture) throws {
    try fixture.database.write { db in
        try db.execute(sql: "DROP TRIGGER fail_vault_note_path_update")
    }
}

@Test func aFailedRepublishThenABareRerunOfTheSameInputLeavesOneRerun() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))
    let clock = try fixedTimeSource(at: firstRerunInstant)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))
    let originalURL = fixture.meetingsSubdirURL.appendingPathComponent("\(expectedLocalDate)-tuesday-sync.md")
    let rerunURL = fixture.meetingsSubdirURL
        .appendingPathComponent("\(expectedLocalDate)-tuesday-sync--rerun-\(expectedFirstRerunDate).md")
    try writeSummaryJSON(summaryJSON(summary: "A revised summary."), to: fixture.cacheDirectory)

    try failVaultNotePathUpdates(fixture)
    let failed = try await fixture.run(meetingID: meetingID, clock: clock)
    guard case let .failed(targetState, errorClass, _, _) = failed else {
        Issue.record("expected .failed outcome, got \(failed)")
        return
    }
    #expect(targetState == .persistFailed)
    #expect(errorClass == "persist_unexpected_error")
    #expect(try listedFiles(fixture) == [originalURL.lastPathComponent, rerunURL.lastPathComponent])
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == originalURL.path)
    let rerunBytes = try Data(contentsOf: rerunURL)
    let rerunModified = try modificationDate(of: rerunURL)

    try allowVaultNotePathUpdates(fixture)
    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))

    #expect(try listedFiles(fixture) == [originalURL.lastPathComponent, rerunURL.lastPathComponent])
    #expect(try Data(contentsOf: rerunURL) == rerunBytes)
    #expect(try modificationDate(of: rerunURL) == rerunModified)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == rerunURL.path)
}

@Test func aStoredNoteTheUserEditedIsNeverOverwrittenAndGetsARerunSibling() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))

    try await requireCompleted(fixture.run(meetingID: meetingID))
    let noteURL = fixture.meetingsSubdirURL.appendingPathComponent("\(expectedLocalDate)-tuesday-sync.md")
    let editedBytes = try Data(contentsOf: noteURL) + Data("\nMy own notes from the meeting.\n".utf8)
    try editedBytes.write(to: noteURL)
    let editedModified = try modificationDate(of: noteURL)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    let rerunURL = fixture.meetingsSubdirURL
        .appendingPathComponent("\(expectedLocalDate)-tuesday-sync--rerun-\(expectedFirstRerunDate).md")
    #expect(try listedFiles(fixture) == [noteURL.lastPathComponent, rerunURL.lastPathComponent])
    #expect(try Data(contentsOf: noteURL) == editedBytes)
    #expect(try modificationDate(of: noteURL) == editedModified)
    let rerunContent = try String(contentsOf: rerunURL, encoding: .utf8)
    #expect(rerunContent.contains("supersedes: \"\(noteURL.lastPathComponent)\""))
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == rerunURL.path)
}

// MARK: - Re-publish: fallback to standard publish

@Test func republishFallsBackToStandardPublishWhenOriginalFileWasDeleted() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let danglingPath = fixture.meetingsSubdirURL.appendingPathComponent("deleted-by-user.md").path

    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue, vaultNotePath: danglingPath))

    let outcome = try await fixture.run(meetingID: meetingID)

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

    let outcome = try await fixture.run(meetingID: meetingID)

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
