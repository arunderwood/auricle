import Core
import Foundation
@testable import Persist
import Testing

private let meetingID = MeetingID(ulid: "01HJK3PQXY7N8M3FT4QHNWVZRP")!

private func makeTestDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func makeMeeting(captureDate: String = "2026-04-28") -> MeetingForFilename {
    MeetingForFilename(
        meetingID: meetingID,
        captureDate: captureDate,
        captureTime24h: "1000",
        calendarEventTitle: "Tuesday Sync",
        attendees: [],
        selfWikilink: nil,
    )
}

private func chmod(_ url: URL, _ permissions: Int) throws {
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
}

// MARK: - Happy path

@Test func writesMarkdownToResolvedPathWhenSubdirAlreadyExists() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)

    let result = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")

    #expect(result == subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md"))
    #expect(try Data(contentsOf: result) == Data("hello".utf8))
}

// MARK: - vaultPath validation

@Test func throwsVaultPathMissingWhenVaultPathDoesNotExist() {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("does-not-exist")

    do {
        _ = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")
        Issue.record("Expected VaultWriter.write to throw")
    } catch let VaultWriter.WriteError.vaultPathMissing(path) {
        #expect(path == vaultPath.path)
    } catch {
        Issue.record("Expected .vaultPathMissing, got \(error)")
    }
}

@Test func throwsVaultPathMissingWhenVaultPathExistsAsARegularFile() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault-file")
    #expect(FileManager.default.createFile(atPath: vaultPath.path, contents: Data()))

    do {
        _ = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")
        Issue.record("Expected VaultWriter.write to throw")
    } catch let VaultWriter.WriteError.vaultPathMissing(path) {
        #expect(path == vaultPath.path)
    } catch {
        Issue.record("Expected .vaultPathMissing, got \(error)")
    }
}

@Test func throwsVaultPathNotWritableWhenExistsAsAReadOnlyDirectory() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    try chmod(vaultPath, 0o500)

    do {
        _ = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")
        Issue.record("Expected VaultWriter.write to throw")
    } catch let VaultWriter.WriteError.vaultPathNotWritable(path) {
        #expect(path == vaultPath.path)
    } catch {
        Issue.record("Expected .vaultPathNotWritable, got \(error)")
    }
}

// MARK: - meetingsSubdir resolution

@Test func autoCreatesMeetingsSubdirWhenMissingInheritingVaultPathPermissions() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    try chmod(vaultPath, 0o701)

    let result = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")

    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: subdirURL.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(result == subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md"))
    let subdirPermissions = try FileManager.default.attributesOfItem(atPath: subdirURL.path)[.posixPermissions] as? Int
    #expect(subdirPermissions == 0o701)
}

@Test func autoCreatesNestedMeetingsSubdirWhenNoComponentExistsYet() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)

    let result = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "inbox/Meetings")

    let subdirURL = vaultPath.appendingPathComponent("inbox/Meetings")
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: subdirURL.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
    #expect(result == subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md"))
}

/// A file blocking a nested path component is the deterministic trigger for
/// creation failure under withIntermediateDirectories: true — a missing
/// parent alone would not fail here, since intermediate creation is enabled.
@Test func throwsMeetingsSubdirCreationFailedWhenAPathComponentIsBlockedByAFile() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let blockerPath = vaultPath.appendingPathComponent("blocker")
    #expect(FileManager.default.createFile(atPath: blockerPath.path, contents: Data()))

    do {
        _ = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "blocker/Meetings")
        Issue.record("Expected VaultWriter.write to throw")
    } catch let VaultWriter.WriteError.meetingsSubdirCreationFailed(path, _) {
        #expect(path == vaultPath.appendingPathComponent("blocker/Meetings").path)
    } catch {
        Issue.record("Expected .meetingsSubdirCreationFailed, got \(error)")
    }
}

@Test func throwsMeetingsSubdirIsNotADirectoryWhenExistsAsAFile() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirPath = vaultPath.appendingPathComponent("Meetings")
    #expect(FileManager.default.createFile(atPath: subdirPath.path, contents: Data()))

    do {
        _ = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")
        Issue.record("Expected VaultWriter.write to throw")
    } catch let VaultWriter.WriteError.meetingsSubdirIsNotADirectory(path) {
        #expect(path == subdirPath.path)
    } catch {
        Issue.record("Expected .meetingsSubdirIsNotADirectory, got \(error)")
    }
}

@Test func throwsMeetingsSubdirNotWritableWhenExistsAsAReadOnlyDirectory() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    try chmod(subdirURL, 0o500)

    do {
        _ = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")
        Issue.record("Expected VaultWriter.write to throw")
    } catch let VaultWriter.WriteError.meetingsSubdirNotWritable(path) {
        #expect(path == subdirURL.path)
    } catch {
        Issue.record("Expected .meetingsSubdirNotWritable, got \(error)")
    }
}

// MARK: - Collision handling

@Test func retriesWithOrdinalTwoWhenTheUnsuffixedPathAlreadyExists() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    let existingURL = subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md")
    let originalContent = Data("original".utf8)
    try originalContent.write(to: existingURL)

    let result = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")

    #expect(result == subdirURL.appendingPathComponent("2026-04-28-tuesday-sync-2.md"))
    #expect(try Data(contentsOf: existingURL) == originalContent)
    #expect(try Data(contentsOf: result) == Data("hello".utf8))
}

@Test func retriesPastOrdinalTwoWhenBothTheUnsuffixedAndOrdinalTwoPathsAlreadyExist() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    try Data("first".utf8).write(to: subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md"))
    try Data("second".utf8).write(to: subdirURL.appendingPathComponent("2026-04-28-tuesday-sync-2.md"))

    let result = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")

    #expect(result == subdirURL.appendingPathComponent("2026-04-28-tuesday-sync-3.md"))
    #expect(try Data(contentsOf: result) == Data("hello".utf8))
}

@Test func reusesTheUnsuffixedPathWhenItAlreadyHoldsExactlyTheMarkdownBeingWritten() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    let existingURL = subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md")
    try Data("hello".utf8).write(to: existingURL)
    let modifiedBefore = try #require(FileManager.default.attributesOfItem(atPath: existingURL.path)[.modificationDate] as? Date)

    let result = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")

    #expect(result == existingURL)
    #expect(try FileManager.default.contentsOfDirectory(atPath: subdirURL.path) == [existingURL.lastPathComponent])
    let modifiedAfter = try FileManager.default.attributesOfItem(atPath: existingURL.path)[.modificationDate] as? Date
    #expect(modifiedAfter == modifiedBefore)
}

@Test func reusesAnOrdinalPathThatHoldsTheMarkdownBeingWrittenAfterSkippingAForeignOne() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    try Data("foreign".utf8).write(to: subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md"))
    let ownURL = subdirURL.appendingPathComponent("2026-04-28-tuesday-sync-2.md")
    try Data("hello".utf8).write(to: ownURL)

    let result = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")

    #expect(result == ownURL)
    #expect(try FileManager.default.contentsOfDirectory(atPath: subdirURL.path).count == 2)
}

@Test func advancesToOrdinalTwoWhenTheExistingFileDiffersByASingleByte() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    let existingURL = subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md")
    let existingContent = Data("hello\n".utf8)
    try existingContent.write(to: existingURL)

    let result = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")

    #expect(result == subdirURL.appendingPathComponent("2026-04-28-tuesday-sync-2.md"))
    #expect(try Data(contentsOf: existingURL) == existingContent)
    #expect(try Data(contentsOf: result) == Data("hello".utf8))
}

/// References VaultWriter.maxCollisionOrdinal directly (internal access, via
/// @testable import) rather than a hardcoded duplicate that could drift from
/// the real cap.
@Test func throwsCollisionRetriesExhaustedWhenEveryOrdinalUpToTheCapCollides() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    let meeting = makeMeeting()

    for ordinal in 1 ... VaultWriter.maxCollisionOrdinal {
        let filename = FilenameResolver.resolve(meeting: meeting, ordinal: ordinal)
        #expect(FileManager.default.createFile(atPath: subdirURL.appendingPathComponent(filename).path, contents: Data()))
    }

    do {
        _ = try VaultWriter.write("hello", meeting: meeting, vaultPath: vaultPath, meetingsSubdir: "Meetings")
        Issue.record("Expected VaultWriter.write to throw")
    } catch let VaultWriter.WriteError.collisionRetriesExhausted(path, maxOrdinal) {
        let lastCandidateFilename = FilenameResolver.resolve(meeting: meeting, ordinal: VaultWriter.maxCollisionOrdinal)
        #expect(path == subdirURL.appendingPathComponent(lastCandidateFilename).path)
        #expect(maxOrdinal == VaultWriter.maxCollisionOrdinal)
    } catch {
        Issue.record("Expected .collisionRetriesExhausted, got \(error)")
    }
}

// MARK: - Process-kill recovery

@Test func processKillBeforeRenameRecoversOnNextWrite() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    let targetURL = subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md")
    let tempURL = AtomicWriter.temporaryURL(for: targetURL)

    // Simulates a kill after AtomicWriter's temp write but before its
    // rename: write directly to the well-known temp path, the same pattern
    // AtomicWriterTests.swift uses to exercise AtomicWriter's own recovery.
    try Data("partial".utf8).write(to: tempURL)
    #expect(FileManager.default.fileExists(atPath: tempURL.path))
    #expect(!FileManager.default.fileExists(atPath: targetURL.path))

    let result = try VaultWriter.write("complete", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")

    #expect(result == targetURL)
    #expect(try Data(contentsOf: targetURL) == Data("complete".utf8))
    #expect(!FileManager.default.fileExists(atPath: tempURL.path))
}

// MARK: - AtomicWriter error propagation

/// A directory (not a file) at the resolved temp path is the deterministic
/// trigger: AtomicWriter's own `createFile` call fails with `EISDIR`, no
/// race required.
@Test func propagatesAtomicWriterErrorWhenTheTempPathIsBlockedByADirectory() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    let targetURL = subdirURL.appendingPathComponent("2026-04-28-tuesday-sync.md")
    let tempURL = AtomicWriter.temporaryURL(for: targetURL)
    try FileManager.default.createDirectory(at: tempURL, withIntermediateDirectories: true)

    do {
        _ = try VaultWriter.write("hello", meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")
        Issue.record("Expected VaultWriter.write to throw")
    } catch let AtomicWriter.WriteError.createTemporaryFileFailed(path, errnoValue) {
        #expect(path == tempURL.path)
        #expect(errnoValue != 0)
    } catch {
        Issue.record("Expected AtomicWriter.WriteError.createTemporaryFileFailed, got \(error)")
    }

    #expect(!FileManager.default.fileExists(atPath: targetURL.path))
}

// MARK: - Performance (NFR-P8)

@Test func writes50KBPayloadWithinThePerformanceBudget() throws {
    let directory = makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let vaultPath = directory.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vaultPath, withIntermediateDirectories: true)
    let subdirURL = vaultPath.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: subdirURL, withIntermediateDirectories: true)
    let payload = String(repeating: "a", count: 50 * 1024)

    let clock = ContinuousClock()
    let start = clock.now
    let result = try VaultWriter.write(payload, meeting: makeMeeting(), vaultPath: vaultPath, meetingsSubdir: "Meetings")
    let elapsed = clock.now - start

    #expect(try Data(contentsOf: result).count == payload.utf8.count)
    #expect(elapsed < .milliseconds(500))
}
