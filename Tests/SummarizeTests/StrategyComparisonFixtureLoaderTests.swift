import Core
import Foundation
import Summarize
import Testing

// MARK: - Helpers

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("strategy-comparison-loader-\(UUID().uuidString)")
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

private func writeDirectoryFixture(named name: String, text: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: true)
    try writeFile(transcriptJSON(text: text), named: "\(name)/transcript.json", in: directory)
    try writeFile(Data("{}".utf8), named: "\(name)/expected.json", in: directory)
}

// MARK: - Tests

struct StrategyComparisonFixtureLoaderTests {
    @Test func loadsJSONTranscriptsInFilenameOrderNamedByStemAndIgnoresEverythingElse() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(transcriptJSON(text: "second"), named: "b-standup.json", in: directory)
        try writeFile(transcriptJSON(text: "first"), named: "a-planning.json", in: directory)
        try writeFile(Data("notes".utf8), named: "notes.txt", in: directory)
        try writeFile(transcriptJSON(text: "hidden"), named: ".hidden.json", in: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("folder.json"), withIntermediateDirectories: true)

        let fixtures = try StrategyComparisonFixtureLoader.load(from: directory)

        #expect(fixtures.map(\.name) == ["a-planning", "b-standup"])
        #expect(fixtures.map(\.transcript.text) == ["first", "second"])
        #expect(fixtures[0].transcript.utterances == [CanonicalTranscript.Utterance(speakerLabel: "Speaker_1", start: 0, end: 5)])
    }

    @Test func directoryWithNoJSONThrowsNoTranscriptsFound() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(Data("notes".utf8), named: "notes.txt", in: directory)

        #expect(throws: StrategyComparisonFixtureLoader.LoadError.noTranscriptsFound(directory: directory.path)) {
            try StrategyComparisonFixtureLoader.load(from: directory)
        }
    }

    @Test func emptyDirectoryThrowsNoTranscriptsFound() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: StrategyComparisonFixtureLoader.LoadError.noTranscriptsFound(directory: directory.path)) {
            try StrategyComparisonFixtureLoader.load(from: directory)
        }
    }

    @Test func missingDirectoryThrowsDirectoryUnreadable() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("strategy-comparison-missing-\(UUID().uuidString)")

        #expect(throws: StrategyComparisonFixtureLoader.LoadError.directoryUnreadable(path: directory.path)) {
            try StrategyComparisonFixtureLoader.load(from: directory)
        }
    }

    @Test func malformedFixtureThrowsNamingTheFileNeverItsContents() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(transcriptJSON(text: "fine"), named: "a-good.json", in: directory)
        try writeFile(Data("SECRET-CONTENT this is not json".utf8), named: "b-bad.json", in: directory)

        do {
            _ = try StrategyComparisonFixtureLoader.load(from: directory)
            Issue.record("expected malformedFixture")
        } catch let error as StrategyComparisonFixtureLoader.LoadError {
            #expect(error == .malformedFixture(fileName: "b-bad.json"))
            #expect(error.localizedDescription.contains("b-bad.json"))
            #expect(!error.localizedDescription.contains("SECRET"))
        } catch {
            Issue.record("unexpected error type: \(type(of: error))")
        }
    }

    @Test func loadsNameSubdirectoriesAlongsideFlatFilesInNameOrderIgnoringWhatElseTheyHold() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(transcriptJSON(text: "flat"), named: "b-flat.json", in: directory)
        try writeDirectoryFixture(named: "a-dir", text: "from a directory", in: directory)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("no-transcript"), withIntermediateDirectories: true)
        try writeFile(Data("notes".utf8), named: "no-transcript/notes.txt", in: directory)
        try writeFile(Data("readme".utf8), named: "README.md", in: directory)

        let fixtures = try StrategyComparisonFixtureLoader.load(from: directory)

        #expect(fixtures.map(\.name) == ["a-dir", "b-flat"])
        #expect(fixtures.map(\.transcript.text) == ["from a directory", "flat"])
    }

    @Test func aSubdirectoryWithoutATranscriptIsNotAFixture() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let empty = directory.appendingPathComponent("empty-fixture")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty.appendingPathComponent("transcript.json"), withIntermediateDirectories: true)

        #expect(throws: StrategyComparisonFixtureLoader.LoadError.noTranscriptsFound(directory: directory.path)) {
            try StrategyComparisonFixtureLoader.load(from: directory)
        }
    }

    @Test func aFlatFileAndASubdirectoryWithTheSameNameAreRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(transcriptJSON(text: "flat"), named: "standup.json", in: directory)
        try writeDirectoryFixture(named: "standup", text: "directory", in: directory)

        #expect(throws: StrategyComparisonFixtureLoader.LoadError.duplicateFixtureName(name: "standup")) {
            try StrategyComparisonFixtureLoader.load(from: directory)
        }
    }

    @Test func aMalformedDirectoryTranscriptIsNamedByItsRelativePathNeverItsContents() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("bad"), withIntermediateDirectories: true)
        try writeFile(Data("SECRET-CONTENT this is not json".utf8), named: "bad/transcript.json", in: directory)

        do {
            _ = try StrategyComparisonFixtureLoader.load(from: directory)
            Issue.record("expected malformedFixture")
        } catch let error as StrategyComparisonFixtureLoader.LoadError {
            #expect(error == .malformedFixture(fileName: "bad/transcript.json"))
            #expect(!error.localizedDescription.contains("SECRET"))
        } catch {
            Issue.record("unexpected error type: \(type(of: error))")
        }
    }

    @Test func theCommittedEvalFixturesLoadThroughTheDirectoryLayout() throws {
        let evalDirectory = try #require(EvalFixtures.directory)

        let fixtures = try StrategyComparisonFixtureLoader.load(from: evalDirectory)

        #expect(fixtures.count >= 5)
        #expect(fixtures.map(\.name) == EvalFixtures.names)
        for fixture in fixtures {
            #expect(try fixture.transcript == EvalFixtures.load(fixture.name).transcript)
        }
    }

    @Test func validJSONOfTheWrongShapeIsMalformedToo() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeFile(Data(#"{"text": 1}"#.utf8), named: "wrong-shape.json", in: directory)

        #expect(throws: StrategyComparisonFixtureLoader.LoadError.malformedFixture(fileName: "wrong-shape.json")) {
            try StrategyComparisonFixtureLoader.load(from: directory)
        }
    }
}
