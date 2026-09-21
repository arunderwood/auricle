import Foundation
import RecallBench
import Testing

@Test
func loadsEveryManifestMeetingInOrder() throws {
    let fixtures = try RecallBenchFixtureLoader.load(repoRoot: repoRoot)

    #expect(fixtures.map(\.id) == ["ES2002a", "ES2002b", "ES2003a", "ES2003b", "ES2004a"])
    #expect(fixtures.allSatisfy { !$0.transcript.utterances.isEmpty })
    #expect(fixtures.first?.directory.lastPathComponent == "ami-es2002a")
    #expect(fixtures.last?.directory.lastPathComponent == "es2004a")
}

@Test
func aRepoRootWithoutTheManifestIsUnreadable() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }

    #expect(throws: RecallBenchFixtureLoader.LoadError.manifestUnreadable) {
        try RecallBenchFixtureLoader.load(repoRoot: root.url)
    }
}

@Test
func aManifestThatIsNotTheExpectedJSONIsUndecodable() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try root.writeManifest("{\"meetings\": \"not a list\"}")

    #expect(throws: RecallBenchFixtureLoader.LoadError.manifestUndecodable) {
        try RecallBenchFixtureLoader.load(repoRoot: root.url)
    }
}

@Test
func anAbsentReferenceDirectoryNamesTheMeetingItBelongsTo() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try root.writeManifest(#"{"meetings": [{"id": "ES9999a", "reference": "Tests/nowhere"}]}"#)

    #expect(throws: RecallBenchFixtureLoader.LoadError.fixtureMissing(id: "ES9999a")) {
        try RecallBenchFixtureLoader.load(repoRoot: root.url)
    }
}

@Test
func aTranscriptThatIsNotACanonicalTranscriptNamesTheMeetingItBelongsTo() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try root.writeManifest(#"{"meetings": [{"id": "ES9999a", "reference": "reference/es9999a"}]}"#)
    try root.writeFixtureFile("reference/es9999a/transcript.json", contents: #"{"text": "no utterances key"}"#)

    #expect(throws: RecallBenchFixtureLoader.LoadError.transcriptUndecodable(id: "ES9999a")) {
        try RecallBenchFixtureLoader.load(repoRoot: root.url)
    }
}

/// The scorer reads `expected.json`, and it runs only after the meeting's
/// paid call, so a fixture without one has to fail the load rather than the
/// whole spent run.
@Test
func aReferenceDirectoryWithoutExpectedItemsFailsBeforeAnyCall() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try root.writeManifest(#"{"meetings": [{"id": "ES9999a", "reference": "reference/es9999a"}]}"#)
    try root.writeFixtureFile(
        "reference/es9999a/transcript.json",
        contents: #"{"text": "Speaker_1: hello", "utterances": [{"speaker_label": "Speaker_1", "start": 0, "end": 16}]}"#,
    )

    #expect(throws: RecallBenchFixtureLoader.LoadError.expectedItemsMissing(id: "ES9999a")) {
        try RecallBenchFixtureLoader.load(repoRoot: root.url)
    }
}
