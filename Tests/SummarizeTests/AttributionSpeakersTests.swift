import Core
import Foundation
@testable import Summarize
import Testing

private func makeDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func plant(_ json: String, in directory: URL) throws {
    try AtomicWriter.write(Data(json.utf8), to: directory.appendingPathComponent("attribution.json"))
}

@Test func absentFileIsNilNotAnEmptyMap() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try AttributionSpeakers.read(in: directory) == nil)
}

@Test func readsOnlyTheSpeakersObjectAndIgnoresEveryOtherKey() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try plant(
        """
        {
          "schema_version": 1,
          "speakers": {"Speaker_1": "[[Ada]]", "Speaker_2": "[[Ben]]"},
          "segment_overrides": [{"segment_id": "s1", "speaker": "Speaker_2"}],
          "segment_splits": "not even an array",
          "something_new": {"nested": true}
        }
        """,
        in: directory,
    )

    #expect(try AttributionSpeakers.read(in: directory) == ["Speaker_1": "[[Ada]]", "Speaker_2": "[[Ben]]"])
}

@Test func presentFileWithNoSpeakersNamedIsAnEmptyMap() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try plant(#"{"speakers": {}}"#, in: directory)

    #expect(try AttributionSpeakers.read(in: directory) == [:])
}

@Test func emptyAndWhitespaceOnlyValuesAreAbsentFromTheResult() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try plant(#"{"speakers": {"Speaker_1": "", "Speaker_2": " \t\n", "Speaker_3": "[[Cy]]"}}"#, in: directory)

    #expect(try AttributionSpeakers.read(in: directory) == ["Speaker_3": "[[Cy]]"])
}

@Test func malformedFileThrowsAttributionUndecodable() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    for json in ["not json", "{}", #"{"speakers": ["a"]}"#, #"{"speakers": {"Speaker_1": 7}}"#] {
        try plant(json, in: directory)
        #expect(throws: SummarizeStageError.attributionUndecodable) {
            try AttributionSpeakers.read(in: directory)
        }
    }
}

@Test func aSpeakerMappedToItselfIsDroppedLikeABlankOne() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try plant(#"{"speakers": {"Speaker_1": "Speaker_1", "Speaker_2": "[[Cy]]"}}"#, in: directory)

    #expect(try AttributionSpeakers.read(in: directory) == ["Speaker_2": "[[Cy]]"])
}

@Test func utteranceSpeakersJoinsDiarizationWithTheWholeAttributionFile() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try AtomicWriter.write(Data(#"""
    {"segments": [
      {"id": "seg_1", "speaker_label": "Speaker_1", "start_seconds": 0, "end_seconds": 1, "utterance_index": {"first": 0, "last": 0}, "voice_profile": {"overlap_ratio": 0}},
      {"id": "seg_2", "speaker_label": "Speaker_2", "start_seconds": 1, "end_seconds": 2, "utterance_index": {"first": 1, "last": 1}, "voice_profile": {"overlap_ratio": 0}}
    ]}
    """#.utf8), to: directory.appendingPathComponent("diarization.json"))
    try plant(#"{"speakers": {"Speaker_1": "[[Ada]]", "Speaker_2": "[[Ben]]"}, "segment_overrides": [{"segment_id": "seg_2", "speaker": "[[Cy]]"}]}"#, in: directory)

    #expect(try AttributionSpeakers.utteranceSpeakers(in: directory, utteranceCount: 2) == ["[[Ada]]", "[[Cy]]"])
}

@Test func utteranceSpeakersIsNilWithoutDiarizationAndThrowsWhenItIsDamaged() throws {
    let directory = try makeDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(try AttributionSpeakers.utteranceSpeakers(in: directory, utteranceCount: 2) == nil)
    try AtomicWriter.write(Data("nope".utf8), to: directory.appendingPathComponent("diarization.json"))
    #expect(throws: SummarizeStageError.diarizationUndecodable) {
        try AttributionSpeakers.utteranceSpeakers(in: directory, utteranceCount: 2)
    }
}
