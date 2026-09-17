@testable import Core
import Foundation
import Testing

@Test func canonicalTranscriptRoundTripsAndUsesSnakeCaseKeys() throws {
    let value = CanonicalTranscript(
        text: "Hello world",
        utterances: [
            CanonicalTranscript.Utterance(speakerLabel: "Speaker_1", start: 0, end: 5),
            CanonicalTranscript.Utterance(speakerLabel: "Speaker_2", start: 6, end: 11),
        ],
    )

    let data = try JSONEncoder().encode(value)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"speaker_label\""))
    #expect(!json.contains("\"speakerLabel\""))

    let decoded = try JSONDecoder().decode(CanonicalTranscript.self, from: data)
    #expect(decoded == value)
}

@Test func canonicalTranscriptUtteranceCountReflectsUtterances() {
    let value = CanonicalTranscript(
        text: "Hello world",
        utterances: [
            CanonicalTranscript.Utterance(speakerLabel: "Speaker_1", start: 0, end: 5),
            CanonicalTranscript.Utterance(speakerLabel: "Speaker_2", start: 6, end: 11),
        ],
    )

    #expect(value.utteranceCount == 2)
}
