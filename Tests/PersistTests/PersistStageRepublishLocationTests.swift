@testable import Core
import Foundation
import Orchestrator
@testable import Persist
@testable import State
import Testing

// Where a re-run is written (the configured meetings folder) and how the
// stage finds the meeting's existing note when the stored path no longer
// names one (by `auricle.meeting_id`, not by location).

private let originalName = "\(expectedLocalDate)-tuesday-sync.md"
private let firstRerunName = "\(expectedLocalDate)-tuesday-sync--rerun-\(expectedFirstRerunDate).md"

private func insertMeeting(_ fixture: TestFixture) async throws -> MeetingID {
    let meetingID = MeetingID.generate()
    try await fixture.store.insertMeeting(makeMeetingRow(id: meetingID.rawValue))
    return meetingID
}

/// Publishes the meeting's first note into the fixture's `Meetings` folder.
private func publishOriginal(_ fixture: TestFixture, _ meetingID: MeetingID) async throws -> URL {
    try await requireCompleted(fixture.run(meetingID: meetingID))
    return fixture.meetingsSubdirURL.appendingPathComponent(originalName)
}

private func reviseSummary(_ fixture: TestFixture, to summary: String = "A revised summary.") throws {
    try writeSummaryJSON(summaryJSON(summary: summary), to: fixture.cacheDirectory)
}

private func requireFailed(_ outcome: StageRunner.StageOutcome) throws -> String {
    guard case let .failed(targetState, errorClass, _, _) = outcome else {
        Issue.record("expected .failed outcome, got \(outcome)")
        throw CancellationError()
    }
    #expect(targetState == .persistFailed)
    return errorClass
}

private func files(in directory: URL) throws -> Set<String> {
    try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
}

// MARK: - Re-runs go to the configured folder

@Test func aChangedMeetingsSubdirSendsTheRerunToTheNewFolder() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let originalURL = try await publishOriginal(fixture, meetingID)
    let originalBytes = try Data(contentsOf: originalURL)
    try reviseSummary(fixture)

    try await requireCompleted(fixture.run(
        meetingID: meetingID,
        meetingsSubdir: "Inbox/Meetings",
        clock: fixedTimeSource(at: firstRerunInstant),
    ))

    let newFolder = fixture.vaultPath.appendingPathComponent("Inbox/Meetings")
    let rerunURL = newFolder.appendingPathComponent(firstRerunName)
    #expect(try files(in: newFolder) == [firstRerunName])
    let rerunContent = try String(contentsOf: rerunURL, encoding: .utf8)
    #expect(rerunContent.contains("supersedes: \"\(originalName)\""))
    #expect(rerunContent.contains("A revised summary."))
    #expect(try listedFiles(fixture) == [originalName])
    #expect(try Data(contentsOf: originalURL) == originalBytes)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == rerunURL.path)
}

@Test func aRerunIntoAMissingVaultPathFailsAndLeavesTheStoredNoteAlone() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let originalURL = try await publishOriginal(fixture, meetingID)
    let originalBytes = try Data(contentsOf: originalURL)
    try reviseSummary(fixture)
    let missingVault = fixture.directory.appendingPathComponent("gone-vault")

    let outcome = try await fixture.run(
        meetingID: meetingID,
        vaultPath: missingVault,
        clock: fixedTimeSource(at: firstRerunInstant),
    )

    #expect(try requireFailed(outcome) == "vault_write_failed")
    #expect(!FileManager.default.fileExists(atPath: missingVault.path))
    #expect(try listedFiles(fixture) == [originalName])
    #expect(try Data(contentsOf: originalURL) == originalBytes)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == originalURL.path)
}

@Test func aRerunIntoASubdirThatIsAFileFailsWithTheVaultWriteError() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    _ = try await publishOriginal(fixture, meetingID)
    try reviseSummary(fixture)
    try Data().write(to: fixture.vaultPath.appendingPathComponent("NotAFolder"))

    let outcome = try await fixture.run(
        meetingID: meetingID,
        meetingsSubdir: "NotAFolder",
        clock: fixedTimeSource(at: firstRerunInstant),
    )

    #expect(try requireFailed(outcome) == "vault_write_failed")
    #expect(try listedFiles(fixture) == [originalName])
}

@Test func anUnchangedNoteIsKeptAndTheConfiguredFolderIsNotCreated() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let originalURL = try await publishOriginal(fixture, meetingID)
    let originalBytes = try Data(contentsOf: originalURL)

    try await requireCompleted(fixture.run(meetingID: meetingID, meetingsSubdir: "Elsewhere"))

    #expect(!FileManager.default.fileExists(atPath: fixture.vaultPath.appendingPathComponent("Elsewhere").path))
    #expect(try Data(contentsOf: originalURL) == originalBytes)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == originalURL.path)
}

@Test func aStoredPathOutsideTheConfiguredFolderStillCountsAndTheRerunLandsInTheConfiguredFolder() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let oldVault = fixture.directory.appendingPathComponent("old-vault")
    let oldFolder = oldVault.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
    try await requireCompleted(fixture.run(meetingID: meetingID, vaultPath: oldVault))
    let oldNoteURL = oldFolder.appendingPathComponent(originalName)
    let oldNoteBytes = try Data(contentsOf: oldNoteURL)
    try reviseSummary(fixture)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    let rerunURL = fixture.meetingsSubdirURL.appendingPathComponent(firstRerunName)
    #expect(try listedFiles(fixture) == [firstRerunName])
    #expect(try files(in: oldFolder) == [originalName])
    #expect(try Data(contentsOf: oldNoteURL) == oldNoteBytes)
    let rerunContent = try String(contentsOf: rerunURL, encoding: .utf8)
    #expect(rerunContent.contains("supersedes: \"\(originalName)\""))
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == rerunURL.path)
}

// MARK: - A note the stored path no longer names is found by meeting_id

@Test func aNoteRenamedInsideTheFolderIsFoundAndSupersededByItsNewFilename() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let originalURL = try await publishOriginal(fixture, meetingID)
    let renamedURL = fixture.meetingsSubdirURL.appendingPathComponent("Our Tuesday Sync.md")
    try FileManager.default.moveItem(at: originalURL, to: renamedURL)
    let renamedBytes = try Data(contentsOf: renamedURL)
    try reviseSummary(fixture)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    let rerunName = "Our Tuesday Sync--rerun-\(expectedFirstRerunDate).md"
    let rerunURL = fixture.meetingsSubdirURL.appendingPathComponent(rerunName)
    #expect(try listedFiles(fixture) == [renamedURL.lastPathComponent, rerunName])
    let rerunContent = try String(contentsOf: rerunURL, encoding: .utf8)
    #expect(rerunContent.contains("supersedes: \"Our Tuesday Sync.md\""))
    #expect(try Data(contentsOf: renamedURL) == renamedBytes)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == rerunURL.path)
}

@Test func aRenamedNoteWithUnchangedContentIsKeptAndItsNewPathRecorded() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let originalURL = try await publishOriginal(fixture, meetingID)
    let renamedURL = fixture.meetingsSubdirURL.appendingPathComponent("Renamed.md")
    try FileManager.default.moveItem(at: originalURL, to: renamedURL)
    let renamedBytes = try Data(contentsOf: renamedURL)
    let renamedModified = try modificationDate(of: renamedURL)

    try await requireCompleted(fixture.run(meetingID: meetingID))

    #expect(try listedFiles(fixture) == ["Renamed.md"])
    #expect(try Data(contentsOf: renamedURL) == renamedBytes)
    #expect(try modificationDate(of: renamedURL) == renamedModified)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == renamedURL.path)
}

@Test func aNoteMovedIntoASubfolderIsFoundAndTheRerunLandsInTheConfiguredFolder() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let originalURL = try await publishOriginal(fixture, meetingID)
    let archive = fixture.meetingsSubdirURL.appendingPathComponent("2026/Archive")
    try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
    let movedURL = archive.appendingPathComponent(originalName)
    try FileManager.default.moveItem(at: originalURL, to: movedURL)
    let movedBytes = try Data(contentsOf: movedURL)
    try reviseSummary(fixture)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    let rerunURL = fixture.meetingsSubdirURL.appendingPathComponent(firstRerunName)
    #expect(try listedFiles(fixture) == ["2026", firstRerunName])
    #expect(try files(in: archive) == [originalName])
    #expect(try Data(contentsOf: movedURL) == movedBytes)
    let rerunContent = try String(contentsOf: rerunURL, encoding: .utf8)
    #expect(rerunContent.contains("supersedes: \"\(originalName)\""))
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == rerunURL.path)
}

@Test func aDeletedOriginalGivesAFreshPublishWithNoSupersedes() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let originalURL = try await publishOriginal(fixture, meetingID)
    try FileManager.default.removeItem(at: originalURL)
    try reviseSummary(fixture)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    #expect(try listedFiles(fixture) == [originalName])
    let content = try String(contentsOf: originalURL, encoding: .utf8)
    #expect(!content.contains("supersedes"))
    #expect(content.contains("A revised summary."))
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == originalURL.path)
}

@Test func anOriginalAndItsRerunsOnDiskGiveTheUnsupersededOneEvenWhenAnotherIsNewer() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let clock = try fixedTimeSource(at: firstRerunInstant)
    let originalURL = try await publishOriginal(fixture, meetingID)
    try reviseSummary(fixture, to: "Second summary.")
    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))
    let firstRerunURL = fixture.meetingsSubdirURL.appendingPathComponent(firstRerunName)
    let firstRerunBytes = try Data(contentsOf: firstRerunURL)
    // A hand edit makes the original the most recently modified file, so only
    // the `supersedes` link can point the lookup at the first re-run.
    try setModificationDate(Date().addingTimeInterval(3600), of: originalURL)
    try clearVaultNotePath(fixture, meetingID)
    try reviseSummary(fixture, to: "Third summary.")

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: clock))

    let secondRerunName = "\(expectedLocalDate)-tuesday-sync--rerun-\(expectedFirstRerunDate)-2.md"
    let secondRerunURL = fixture.meetingsSubdirURL.appendingPathComponent(secondRerunName)
    #expect(try listedFiles(fixture) == [originalName, firstRerunName, secondRerunName])
    let secondRerunContent = try String(contentsOf: secondRerunURL, encoding: .utf8)
    #expect(secondRerunContent.contains("supersedes: \"\(firstRerunName)\""))
    #expect(try Data(contentsOf: firstRerunURL) == firstRerunBytes)
    #expect(try await readMeeting(fixture, meetingID).vaultNotePath == secondRerunURL.path)
}

@Test func whenNoNoteSupersedesTheOthersTheNewestByModificationDateIsThePredecessor() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let newerURL = fixture.meetingsSubdirURL.appendingPathComponent("alpha.md")
    let olderURL = fixture.meetingsSubdirURL.appendingPathComponent("omega.md")
    try plantNote(meetingID: meetingID, at: newerURL)
    try plantNote(meetingID: meetingID, at: olderURL)
    try setModificationDate(Date(timeIntervalSince1970: 1_800_000_000), of: newerURL)
    try setModificationDate(Date(timeIntervalSince1970: 1_700_000_000), of: olderURL)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    let rerunName = "alpha--rerun-\(expectedFirstRerunDate).md"
    let rerunContent = try String(contentsOf: fixture.meetingsSubdirURL.appendingPathComponent(rerunName), encoding: .utf8)
    #expect(rerunContent.contains("supersedes: \"alpha.md\""))
    #expect(try listedFiles(fixture) == ["alpha.md", "omega.md", rerunName])
}

// MARK: - Files that are not this meeting's note

/// Files a scan has to skip without matching: undecodable bytes, no
/// frontmatter, frontmatter without an `auricle` block, a schema version the
/// reader rejects, a non-`.md` extension, and a real note the process cannot read.
private func plantUnmatchableFiles(in folder: URL, meetingID: MeetingID) throws -> (unreadable: URL, names: Set<String>) {
    try Data([0xFF, 0xFE, 0x00, 0xC3, 0x28]).write(to: folder.appendingPathComponent("not-utf8.md"))
    try Data("just some prose\n".utf8).write(to: folder.appendingPathComponent("no-frontmatter.md"))
    try Data("---\ntitle: \"Hello\"\n---\n\nbody\n".utf8).write(to: folder.appendingPathComponent("not-auricle.md"))
    let futureSchema = "---\nauricle:\n  meeting_id: \"\(meetingID.rawValue)\"\n  schema_version: 99\n---\n"
    try Data(futureSchema.utf8).write(to: folder.appendingPathComponent("future-schema.md"))
    try plantNote(meetingID: meetingID, at: folder.appendingPathComponent("named-as-text.txt"))
    let unreadable = folder.appendingPathComponent("unreadable.md")
    try plantNote(meetingID: meetingID, at: unreadable)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
    return (
        unreadable,
        [
            "not-utf8.md", "no-frontmatter.md", "not-auricle.md", "future-schema.md", "named-as-text.txt", "unreadable.md",
        ],
    )
}

@Test func unreadableAndNonNoteFilesAreNeverTakenForTheMeetingsNote() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let planted = try plantUnmatchableFiles(in: fixture.meetingsSubdirURL, meetingID: meetingID)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: planted.unreadable.path) }

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    #expect(try listedFiles(fixture) == planted.names.union([originalName]))
    let content = try String(contentsOf: fixture.meetingsSubdirURL.appendingPathComponent(originalName), encoding: .utf8)
    #expect(!content.contains("supersedes"))
}

@Test func unreadableAndNonNoteFilesDoNotHideTheMeetingsRealNote() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let originalURL = try await publishOriginal(fixture, meetingID)
    let originalBytes = try Data(contentsOf: originalURL)
    try clearVaultNotePath(fixture, meetingID)
    let planted = try plantUnmatchableFiles(in: fixture.meetingsSubdirURL, meetingID: meetingID)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: planted.unreadable.path) }
    try reviseSummary(fixture)

    try await requireCompleted(fixture.run(meetingID: meetingID, clock: fixedTimeSource(at: firstRerunInstant)))

    #expect(try listedFiles(fixture) == planted.names.union([originalName, firstRerunName]))
    let rerunContent = try String(contentsOf: fixture.meetingsSubdirURL.appendingPathComponent(firstRerunName), encoding: .utf8)
    #expect(rerunContent.contains("supersedes: \"\(originalName)\""))
    #expect(try Data(contentsOf: originalURL) == originalBytes)
}

@Test func aNoteWhoseFrontmatterNamesADifferentMeetingIsNotMatched() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    let otherURL = fixture.meetingsSubdirURL.appendingPathComponent("someone-elses.md")
    try plantNote(meetingID: MeetingID.generate(), at: otherURL)
    let otherBytes = try Data(contentsOf: otherURL)

    try await requireCompleted(fixture.run(meetingID: meetingID))

    #expect(try listedFiles(fixture) == ["someone-elses.md", originalName])
    let content = try String(contentsOf: fixture.meetingsSubdirURL.appendingPathComponent(originalName), encoding: .utf8)
    #expect(!content.contains("supersedes"))
    #expect(try Data(contentsOf: otherURL) == otherBytes)
}

@Test func aNoteInAHiddenFolderIsNotSearched() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = try await insertMeeting(fixture)
    try plantNote(meetingID: meetingID, at: fixture.meetingsSubdirURL.appendingPathComponent(".trash/old.md"))

    try await requireCompleted(fixture.run(meetingID: meetingID))

    #expect(try listedFiles(fixture) == [".trash", originalName])
    let content = try String(contentsOf: fixture.meetingsSubdirURL.appendingPathComponent(originalName), encoding: .utf8)
    #expect(!content.contains("supersedes"))
}

// MARK: - PredecessorNoteFinder

private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    var recorded: [String] {
        lock.withLock { lines }
    }

    var log: Log {
        Log(category: "test") { [self] _, message in
            lock.withLock { lines.append(message) }
        }
    }
}

@Test func theScanStopsAtItsFileLimitAndWarnsThroughTheLog() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    for index in 1 ... 4 {
        try Data("note \(index)\n".utf8).write(to: fixture.meetingsSubdirURL.appendingPathComponent("note-\(index).md"))
    }
    let recorder = LogRecorder()

    let found = PredecessorNoteFinder.find(
        meetingID: MeetingID.generate(),
        in: fixture.meetingsSubdirURL,
        maxFiles: 3,
        log: recorder.log,
    )

    #expect(found == nil)
    #expect(recorder.recorded == ["predecessor note scan stopped at its file limit limit=3"])
}

@Test func theScanDoesNotWarnWhenTheFolderHoldsExactlyItsFileLimit() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    for index in 1 ... 3 {
        try Data("note \(index)\n".utf8).write(to: fixture.meetingsSubdirURL.appendingPathComponent("note-\(index).md"))
    }
    let recorder = LogRecorder()

    _ = PredecessorNoteFinder.find(
        meetingID: MeetingID.generate(),
        in: fixture.meetingsSubdirURL,
        maxFiles: 3,
        log: recorder.log,
    )

    #expect(recorder.recorded.isEmpty)
}

@Test func theScanReadsOnlyTheFrontmatterOfALongNote() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let meetingID = MeetingID.generate()
    let noteURL = fixture.meetingsSubdirURL.appendingPathComponent("long.md")
    try plantNote(meetingID: meetingID, at: noteURL)
    let padding = String(repeating: "é word ", count: 10000)
    try Data((String(contentsOf: noteURL, encoding: .utf8) + padding).utf8).write(to: noteURL)

    let found = PredecessorNoteFinder.find(meetingID: meetingID, in: fixture.meetingsSubdirURL)

    #expect(found?.lastPathComponent == "long.md")
}

private func candidate(_ name: String, supersedes: String? = nil, modified: TimeInterval = 0) -> PredecessorNoteFinder.Candidate {
    PredecessorNoteFinder.Candidate(
        url: URL(fileURLWithPath: "/vault/Meetings/\(name)"),
        supersedes: supersedes,
        modified: Date(timeIntervalSince1970: modified),
    )
}

@Test func predecessorIsNilWithoutCandidates() {
    #expect(PredecessorNoteFinder.predecessor(among: []) == nil)
}

@Test func predecessorIsTheCandidateNoOtherCandidateSupersedes() {
    let candidates = [
        candidate("a.md", modified: 300),
        candidate("a--rerun-1.md", supersedes: "a.md", modified: 100),
        candidate("a--rerun-2.md", supersedes: "a--rerun-1.md", modified: 200),
    ]

    #expect(PredecessorNoteFinder.predecessor(among: candidates)?.lastPathComponent == "a--rerun-2.md")
}

@Test func predecessorBreaksAnAmbiguityByModificationDateThenPath() {
    let byDate = [candidate("a.md", modified: 100), candidate("b.md", modified: 200)]
    #expect(PredecessorNoteFinder.predecessor(among: byDate)?.lastPathComponent == "b.md")

    let tied = [candidate("b.md", modified: 100), candidate("a.md", modified: 100)]
    #expect(PredecessorNoteFinder.predecessor(among: tied)?.lastPathComponent == "a.md")
}

@Test func predecessorFallsBackToTheNewestWhenSupersedesLinksLoop() {
    let candidates = [
        candidate("a.md", supersedes: "b.md", modified: 100),
        candidate("b.md", supersedes: "a.md", modified: 200),
    ]

    #expect(PredecessorNoteFinder.predecessor(among: candidates)?.lastPathComponent == "b.md")
}

@Test func aNoteThatListsItselfInSupersedesIsNotSupersededByItself() {
    let candidates = [candidate("a.md", supersedes: "a.md", modified: 100)]

    #expect(PredecessorNoteFinder.predecessor(among: candidates)?.lastPathComponent == "a.md")
}
