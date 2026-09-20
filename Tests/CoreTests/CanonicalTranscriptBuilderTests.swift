@testable import Core
import Foundation
import Testing

private func build(_ pairs: [(String, String)]) -> CanonicalTranscript {
    CanonicalTranscriptBuilder.build(pairs.map { (speakerLabel: $0.0, text: $0.1) })
}

/// The slice of `transcript.text` an utterance's byte range names.
private func slice(_ utterance: CanonicalTranscript.Utterance, of transcript: CanonicalTranscript) -> String? {
    let bytes = Array(transcript.text.utf8)
    guard utterance.start >= 0, utterance.start <= utterance.end, utterance.end <= bytes.count else { return nil }
    return String(bytes: bytes[utterance.start ..< utterance.end], encoding: .utf8)
}

@Test func builderPrefixesEachUtteranceAndJoinsThemWithASingleLF() {
    let transcript = build([("Speaker_1", "Hello there."), ("Speaker_2", "General Kenobi.")])

    #expect(transcript.text == "Speaker_1: Hello there.\nSpeaker_2: General Kenobi.")
    #expect(transcript.utterances.map(\.speakerLabel) == ["Speaker_1", "Speaker_2"])
}

@Test func builderRangesIncludeTheirOwnPrefixAndExcludeTheJoiningNewline() throws {
    let transcript = build([("Speaker_1", "Hello there."), ("Speaker_2", "General Kenobi.")])

    let first = try #require(transcript.utterances.first)
    let second = try #require(transcript.utterances.last)
    #expect(slice(first, of: transcript) == "Speaker_1: Hello there.")
    #expect(slice(second, of: transcript) == "Speaker_2: General Kenobi.")
    #expect(first.end + 1 == second.start)
}

@Test func builderOffsetsAreUTF8BytesNotCharacters() throws {
    let transcript = build([("Speaker_1", "café ☕"), ("Speaker_1", "naïve 🚀 plan")])

    #expect(transcript.text.utf8.count > transcript.text.count)
    for utterance in transcript.utterances {
        let text = try #require(slice(utterance, of: transcript))
        #expect(text.hasPrefix("Speaker_1: "))
    }
    let last = try #require(transcript.utterances.last)
    #expect(last.end == transcript.text.utf8.count)
    #expect(slice(last, of: transcript) == "Speaker_1: naïve 🚀 plan")
}

@Test func builderComposesTextToNFC() {
    let decomposed = "cafe\u{301}"
    let transcript = build([("Speaker_1", decomposed)])

    #expect(transcript.text == "Speaker_1: caf\u{E9}")
    #expect(transcript.text.unicodeScalars.map(\.value) == "Speaker_1: caf\u{E9}".unicodeScalars.map(\.value))
    #expect(Array(transcript.text.unicodeScalars) == Array(transcript.text.precomposedStringWithCanonicalMapping.unicodeScalars))
}

@Test func builderTurnsEveryLineBreakFormIntoLF() {
    let transcript = build([("Speaker_1", "one\r\ntwo\rthree\u{2028}four\u{85}five")])

    #expect(transcript.text == "Speaker_1: one\ntwo\nthree\nfour\nfive")
    #expect(!transcript.text.contains("\r"))
}

@Test func builderTrimsEveryLineAndDropsBlankOnes() {
    let transcript = build([("Speaker_1", "  \t first  \n\n   \n   second\u{A0}\n")])

    #expect(transcript.text == "Speaker_1: first\nsecond")
    for line in transcript.text.components(separatedBy: "\n") {
        #expect(line == line.trimmingCharacters(in: .whitespaces))
    }
}

@Test func builderDropsUtterancesWithNoTextLeft() {
    let transcript = build([("Speaker_1", "  "), ("Speaker_1", "kept"), ("Speaker_2", "\r\n\t"), ("Speaker_2", ""), ("Speaker_3", "also kept")])

    #expect(transcript.text == "Speaker_1: kept\nSpeaker_3: also kept")
    #expect(transcript.utterances.map(\.speakerLabel) == ["Speaker_1", "Speaker_3"])
    #expect(transcript.utterances.first?.start == 0)
}

@Test func builderReturnsAnEmptyTranscriptForNoUtterances() {
    let transcript = build([])
    let blankOnly = build([("Speaker_1", " "), ("Speaker_1", "")])

    #expect(transcript.text.isEmpty)
    #expect(transcript.utterances.isEmpty)
    #expect(blankOnly == transcript)
}

@Test func builderHasNoTrailingNewlineAndTheLastRangeEndsAtTheText() throws {
    let transcript = build([("Speaker_1", "a"), ("Speaker_2", "b")])

    #expect(!transcript.text.hasSuffix("\n"))
    #expect(try #require(transcript.utterances.last).end == transcript.text.utf8.count)
}

@Test func builderOutputSurvivesAJSONRoundTrip() throws {
    let transcript = build([("Speaker_1", "café"), ("Speaker_1", "🚀 launch")])

    let data = try JSONEncoder().encode(transcript)
    let decoded = try JSONDecoder().decode(CanonicalTranscript.self, from: data)

    #expect(decoded == transcript)
}

@Test func builderReportsWhichInputPositionsSurvived() {
    let built = CanonicalTranscriptBuilder.buildReportingKeptIndices([
        (speakerLabel: "Speaker_1", text: "kept"),
        (speakerLabel: "Speaker_1", text: "   "),
        (speakerLabel: "Speaker_1", text: "\n"),
        (speakerLabel: "Speaker_1", text: "also kept"),
    ])

    #expect(built.keptIndices == [0, 3])
    #expect(built.transcript.utterances.count == 2)
    #expect(built.transcript == build([("Speaker_1", "kept"), ("Speaker_1", "also kept")]))
}
