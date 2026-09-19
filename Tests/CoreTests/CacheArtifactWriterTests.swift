@testable import Core
import Foundation
import Testing

private struct FixtureArtifact: Codable, Equatable {
    let text: String
    let wordCount: Int

    enum CodingKeys: String, CodingKey {
        case text
        case wordCount = "word_count"
    }
}

/// `id` is a fresh ULID per test, so removing its own cache subdirectory here
/// never touches another test's data or anything a real run left behind
/// under the shared `~/Library/Caches/com.auricle.app/`.
private func cleanUp(_ id: MeetingID) {
    guard let directory = try? CacheArtifactWriter.cacheDirectory(for: id) else { return }
    try? FileManager.default.removeItem(at: directory)
}

@Test func writeInjectsSchemaVersionAlongsideDialectFields() throws {
    let id = MeetingID.generate()
    defer { cleanUp(id) }
    let artifact = FixtureArtifact(text: "hello world", wordCount: 2)

    try CacheArtifactWriter.write(artifact, for: id, named: "transcript.json", schemaVersion: 1)

    let target = try CacheArtifactWriter.cacheDirectory(for: id).appendingPathComponent("transcript.json")
    let data = try Data(contentsOf: target)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["schema_version"] as? Int == 1)
    #expect(json["text"] as? String == "hello world")
    #expect(json["word_count"] as? Int == 2)

    let decoded = try JSONDecoder().decode(FixtureArtifact.self, from: data)
    #expect(decoded == artifact)
}

@Test func writeCreatesMeetingDirectoryWhenMissing() throws {
    let id = MeetingID.generate()
    defer { cleanUp(id) }
    let directory = try CacheArtifactWriter.cacheDirectory(for: id)
    #expect(!FileManager.default.fileExists(atPath: directory.path))

    try CacheArtifactWriter.write(FixtureArtifact(text: "x", wordCount: 1), for: id, named: "transcript.json", schemaVersion: 1)

    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
    #expect(exists && isDirectory.boolValue)
}

@Test func writeSetsFilePermissionsTo0600() throws {
    let id = MeetingID.generate()
    defer { cleanUp(id) }

    try CacheArtifactWriter.write(FixtureArtifact(text: "x", wordCount: 1), for: id, named: "transcript.json", schemaVersion: 1)

    let target = try CacheArtifactWriter.cacheDirectory(for: id).appendingPathComponent("transcript.json")
    let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
}

@Test func writeLeavesNoTempFileBehind() throws {
    let id = MeetingID.generate()
    defer { cleanUp(id) }

    try CacheArtifactWriter.write(FixtureArtifact(text: "x", wordCount: 1), for: id, named: "transcript.json", schemaVersion: 1)

    let target = try CacheArtifactWriter.cacheDirectory(for: id).appendingPathComponent("transcript.json")
    #expect(!FileManager.default.fileExists(atPath: AtomicWriter.temporaryURL(for: target).path))
}

@Test func rerunOverwritesArtifactAtomically() throws {
    let id = MeetingID.generate()
    defer { cleanUp(id) }

    try CacheArtifactWriter.write(FixtureArtifact(text: "first", wordCount: 1), for: id, named: "transcript.json", schemaVersion: 1)
    try CacheArtifactWriter.write(FixtureArtifact(text: "second", wordCount: 1), for: id, named: "transcript.json", schemaVersion: 2)

    let target = try CacheArtifactWriter.cacheDirectory(for: id).appendingPathComponent("transcript.json")
    let data = try Data(contentsOf: target)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["text"] as? String == "second")
    #expect(json["schema_version"] as? Int == 2)
    #expect(!FileManager.default.fileExists(atPath: AtomicWriter.temporaryURL(for: target).path))
}

@Test func writeThrowsNotATopLevelJSONObjectForNonObjectEncodable() throws {
    let id = MeetingID.generate()
    defer { cleanUp(id) }
    let target = try CacheArtifactWriter.cacheDirectory(for: id).appendingPathComponent("not-an-object.json")

    do {
        try CacheArtifactWriter.write([1, 2, 3], for: id, named: "not-an-object.json", schemaVersion: 1)
        Issue.record("Expected CacheArtifactWriter.write to throw")
    } catch CacheArtifactWriter.WriteError.notATopLevelJSONObject {
        // expected
    } catch {
        Issue.record("Expected .notATopLevelJSONObject, got \(error)")
    }

    #expect(!FileManager.default.fileExists(atPath: target.path))
}

/// A file blocking the meeting's own cache directory path is the
/// deterministic trigger: `createDirectory(withIntermediateDirectories:
/// true)` still fails when the final path component itself already exists
/// as a regular file, the same pattern `VaultWriterTests`'
/// `throwsMeetingsSubdirCreationFailedWhenAPathComponentIsBlockedByAFile`
/// uses.
@Test func writeThrowsDirectoryCreationFailedWhenPathIsBlockedByAFile() throws {
    let id = MeetingID.generate()
    defer { cleanUp(id) }
    let directory = try CacheArtifactWriter.cacheDirectory(for: id)
    try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
    #expect(FileManager.default.createFile(atPath: directory.path, contents: Data()))

    do {
        try CacheArtifactWriter.write(FixtureArtifact(text: "x", wordCount: 1), for: id, named: "transcript.json", schemaVersion: 1)
        Issue.record("Expected CacheArtifactWriter.write to throw")
    } catch let CacheArtifactWriter.WriteError.directoryCreationFailed(path, _) {
        #expect(path == directory.path)
    } catch {
        Issue.record("Expected .directoryCreationFailed, got \(error)")
    }
}

@Test func cacheDirectoryIsThePerMeetingSubdirectoryOfTheCacheRoot() throws {
    let id = MeetingID.generate()

    let root = try CacheArtifactWriter.cacheRoot()
    let directory = try CacheArtifactWriter.cacheDirectory(for: id)

    #expect(root.lastPathComponent == "com.auricle.app")
    #expect(directory == root.appendingPathComponent(id.rawValue, isDirectory: true))
}

@Test func writeProducesByteIdenticalFilesForIdenticalInput() throws {
    let firstID = MeetingID.generate()
    let secondID = MeetingID.generate()
    defer {
        cleanUp(firstID)
        cleanUp(secondID)
    }
    let transcript = CanonicalTranscript(
        text: "Speaker_1: café\nSpeaker_1: 🚀",
        utterances: [
            .init(speakerLabel: "Speaker_1", start: 0, end: 17),
            .init(speakerLabel: "Speaker_1", start: 18, end: 34),
        ],
    )

    try CacheArtifactWriter.write(transcript, for: firstID, named: "transcript.json", schemaVersion: 1)
    try CacheArtifactWriter.write(transcript, for: secondID, named: "transcript.json", schemaVersion: 1)

    let first = try Data(contentsOf: CacheArtifactWriter.cacheDirectory(for: firstID).appendingPathComponent("transcript.json"))
    let second = try Data(contentsOf: CacheArtifactWriter.cacheDirectory(for: secondID).appendingPathComponent("transcript.json"))
    #expect(first == second)
}

@Test func writeSerializesTopLevelKeysInSortedOrder() throws {
    let id = MeetingID.generate()
    defer { cleanUp(id) }

    try CacheArtifactWriter.write(FixtureArtifact(text: "hello", wordCount: 1), for: id, named: "artifact.json", schemaVersion: 1)

    let data = try Data(contentsOf: CacheArtifactWriter.cacheDirectory(for: id).appendingPathComponent("artifact.json"))
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json == #"{"schema_version":1,"text":"hello","word_count":1}"#)
}
