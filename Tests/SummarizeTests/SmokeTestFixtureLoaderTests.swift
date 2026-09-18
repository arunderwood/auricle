import Core
import Foundation
import Summarize
import Testing

// MARK: - Helpers

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-test-loader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func writeFile(_ contents: Data, named name: String, in directory: URL) throws {
    try AtomicWriter.write(contents, to: directory.appendingPathComponent(name))
}

private func transcriptJSON(text: String) throws -> Data {
    try JSONEncoder().encode(CanonicalTranscript(
        text: text,
        utterances: [CanonicalTranscript.Utterance(speakerLabel: "Speaker_1", start: 0, end: text.utf8.count)],
    ))
}

// MARK: - Tests

struct SmokeTestFixtureLoaderTests {
    @Test func loadsJSONTranscriptsInFilenameOrderNamedByStemAndIgnoresEverythingElse() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(transcriptJSON(text: "second"), named: "b-standup.json", in: directory)
        try writeFile(transcriptJSON(text: "first"), named: "a-planning.json", in: directory)
        try writeFile(Data("notes".utf8), named: "notes.txt", in: directory)
        try writeFile(transcriptJSON(text: "hidden"), named: ".hidden.json", in: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.json"), withIntermediateDirectories: true)

        let fixtures = try SmokeTestFixtureLoader.load(from: directory)

        #expect(fixtures.map(\.name) == ["a-planning", "b-standup"])
        #expect(fixtures.map(\.transcript.text) == ["first", "second"])
        #expect(fixtures[0].transcript.utterances == [CanonicalTranscript.Utterance(speakerLabel: "Speaker_1", start: 0, end: 5)])
    }

    @Test func directoryWithNoJSONThrowsNoTranscriptsFound() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(Data("notes".utf8), named: "notes.txt", in: directory)

        #expect(throws: SmokeTestFixtureLoader.LoadError.noTranscriptsFound(directory: directory.path)) {
            try SmokeTestFixtureLoader.load(from: directory)
        }
    }

    @Test func emptyDirectoryThrowsNoTranscriptsFound() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: SmokeTestFixtureLoader.LoadError.noTranscriptsFound(directory: directory.path)) {
            try SmokeTestFixtureLoader.load(from: directory)
        }
    }

    @Test func missingDirectoryThrowsDirectoryUnreadable() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-test-missing-\(UUID().uuidString)")

        #expect(throws: SmokeTestFixtureLoader.LoadError.directoryUnreadable(path: directory.path)) {
            try SmokeTestFixtureLoader.load(from: directory)
        }
    }

    @Test func malformedFixtureThrowsNamingTheFileNeverItsContents() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(transcriptJSON(text: "fine"), named: "a-good.json", in: directory)
        try writeFile(Data("SECRET-CONTENT this is not json".utf8), named: "b-bad.json", in: directory)

        do {
            _ = try SmokeTestFixtureLoader.load(from: directory)
            Issue.record("expected malformedFixture")
        } catch let error as SmokeTestFixtureLoader.LoadError {
            #expect(error == .malformedFixture(fileName: "b-bad.json"))
            #expect(error.localizedDescription.contains("b-bad.json"))
            #expect(!error.localizedDescription.contains("SECRET"))
        } catch {
            Issue.record("unexpected error type: \(type(of: error))")
        }
    }

    @Test func validJSONOfTheWrongShapeIsMalformedToo() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(Data(#"{"text": 1}"#.utf8), named: "wrong-shape.json", in: directory)

        #expect(throws: SmokeTestFixtureLoader.LoadError.malformedFixture(fileName: "wrong-shape.json")) {
            try SmokeTestFixtureLoader.load(from: directory)
        }
    }
}
