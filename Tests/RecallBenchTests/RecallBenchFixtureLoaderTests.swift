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

/// Two utterances, both written as the `Speaker_1` placeholder, whose
/// `diarization.json` puts the second on a different speaker and whose
/// `attribution.json` names that speaker. Shared by the diarized-load tests
/// below.
private func writeDiarizedFixture(_ root: TemporaryRoot, includeAttribution: Bool = true, includeDiarization: Bool = true) throws {
    try root.writeManifest(#"{"meetings": [{"id": "ES9999a", "reference": "reference/es9999a"}]}"#)
    try root.writeFixtureFile(
        "reference/es9999a/transcript.json",
        contents: #"""
        {
          "text": "Speaker_1: hello there\nSpeaker_1: how are you",
          "utterances": [
            {"speaker_label": "Speaker_1", "start": 0, "end": 22},
            {"speaker_label": "Speaker_1", "start": 23, "end": 45}
          ]
        }
        """#,
    )
    try root.writeFixtureFile("reference/es9999a/expected.json", contents: #"{"action_items": [], "decisions": []}"#)
    if includeDiarization {
        try root.writeFixtureFile(
            "reference/es9999a/diarization.json",
            contents: #"""
            {
              "segments": [
                {"id": "seg_1", "speaker_label": "Speaker_1", "start_seconds": 0, "end_seconds": 1,
                 "utterance_index": {"first": 0, "last": 0}, "voice_profile": {"overlap_ratio": 0}},
                {"id": "seg_2", "speaker_label": "Speaker_2", "start_seconds": 1, "end_seconds": 2,
                 "utterance_index": {"first": 1, "last": 1}, "voice_profile": {"overlap_ratio": 0}}
              ]
            }
            """#,
        )
    }
    guard includeAttribution else { return }
    try root.writeFixtureFile(
        "reference/es9999a/attribution.json",
        contents: #"{"speakers": {"Speaker_2": "[[Real Name]]"}, "segment_overrides": [], "segment_splits": []}"#,
    )
}

@Test
func diarizedFalseLeavesTheTranscriptAsWritten() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try writeDiarizedFixture(root)

    let fixtures = try RecallBenchFixtureLoader.load(repoRoot: root.url)

    #expect(fixtures[0].transcript.utterances.map(\.speakerLabel) == ["Speaker_1", "Speaker_1"])
    #expect(fixtures[0].transcript.text == "Speaker_1: hello there\nSpeaker_1: how are you")
}

@Test
func diarizedTrueJoinsDiarizationAndAttributionIntoTheTranscript() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try writeDiarizedFixture(root)

    let fixtures = try RecallBenchFixtureLoader.load(repoRoot: root.url, diarized: true)

    #expect(fixtures[0].transcript.utterances.map(\.speakerLabel) == ["Speaker_1", "[[Real Name]]"])
    #expect(fixtures[0].transcript.text == "Speaker_1: hello there\n[[Real Name]]: how are you")
}

@Test
func diarizedTrueFallsBackToTheTranscriptAsWrittenWhenAttributionIsMissing() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try writeDiarizedFixture(root, includeAttribution: false)

    let fixtures = try RecallBenchFixtureLoader.load(repoRoot: root.url, diarized: true)

    #expect(fixtures[0].transcript.utterances.map(\.speakerLabel) == ["Speaker_1", "Speaker_1"])
}

@Test
func diarizedTrueFallsBackToTheTranscriptAsWrittenWhenDiarizationIsMissing() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try writeDiarizedFixture(root, includeDiarization: false)

    let fixtures = try RecallBenchFixtureLoader.load(repoRoot: root.url, diarized: true)

    #expect(fixtures[0].transcript.utterances.map(\.speakerLabel) == ["Speaker_1", "Speaker_1"])
}

/// Three utterances, but `diarization.json` only covers indices 0 and 1 —
/// the third falls outside every segment's `utterance_index` range, so
/// `UtteranceSpeakers.resolve` has nothing to return for it.
@Test
func diarizedTrueKeepsTheOriginalLabelForAnUtteranceNoDiarizationSegmentCovers() throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    try root.writeManifest(#"{"meetings": [{"id": "ES9999a", "reference": "reference/es9999a"}]}"#)
    try root.writeFixtureFile(
        "reference/es9999a/transcript.json",
        contents: #"""
        {
          "text": "Speaker_1: hello there\nSpeaker_1: how are you\nSpeaker_1: one more thing",
          "utterances": [
            {"speaker_label": "Speaker_1", "start": 0, "end": 22},
            {"speaker_label": "Speaker_1", "start": 23, "end": 45},
            {"speaker_label": "Speaker_1", "start": 46, "end": 71}
          ]
        }
        """#,
    )
    try root.writeFixtureFile("reference/es9999a/expected.json", contents: #"{"action_items": [], "decisions": []}"#)
    try root.writeFixtureFile(
        "reference/es9999a/diarization.json",
        contents: #"""
        {
          "segments": [
            {"id": "seg_1", "speaker_label": "Speaker_1", "start_seconds": 0, "end_seconds": 1,
             "utterance_index": {"first": 0, "last": 0}, "voice_profile": {"overlap_ratio": 0}},
            {"id": "seg_2", "speaker_label": "Speaker_2", "start_seconds": 1, "end_seconds": 2,
             "utterance_index": {"first": 1, "last": 1}, "voice_profile": {"overlap_ratio": 0}}
          ]
        }
        """#,
    )
    try root.writeFixtureFile(
        "reference/es9999a/attribution.json",
        contents: #"{"speakers": {"Speaker_2": "[[Real Name]]"}, "segment_overrides": [], "segment_splits": []}"#,
    )

    let fixtures = try RecallBenchFixtureLoader.load(repoRoot: root.url, diarized: true)

    #expect(fixtures[0].transcript.utterances.map(\.speakerLabel) == ["Speaker_1", "[[Real Name]]", "Speaker_1"])
}
