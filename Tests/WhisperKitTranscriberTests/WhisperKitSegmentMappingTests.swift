@testable import Core
import Foundation
import Testing
@testable import WhisperKitTranscriber

@Test func everySegmentBecomesOneSpeakerOneUtterance() {
    let transcript = WhisperKitTranscriber.transcript(segmentTexts: [" Hello there.", " General Kenobi."])

    #expect(transcript.text == "Speaker_1: Hello there.\nSpeaker_1: General Kenobi.")
    #expect(transcript.utterances.map(\.speakerLabel) == ["Speaker_1", "Speaker_1"])
}

@Test func specialTokensAreRemovedFromSegmentText() {
    let transcript = WhisperKitTranscriber.transcript(segmentTexts: [
        "<|startoftranscript|><|en|><|transcribe|><|0.00|> Hello there.<|2.40|>",
        " Second segment.<|endoftext|>",
    ])

    #expect(transcript.text == "Speaker_1: Hello there.\nSpeaker_1: Second segment.")
    #expect(!transcript.text.contains("<|"))
}

@Test func aSegmentOfOnlySpecialTokensOrWhitespaceIsDropped() {
    let transcript = WhisperKitTranscriber.transcript(segmentTexts: ["<|nospeech|>", "   ", "", " kept ", "<|0.00|>  <|1.00|>"])

    #expect(transcript.text == "Speaker_1: kept")
    #expect(transcript.utterances.count == 1)
    #expect(transcript.utterances.first?.start == 0)
}

@Test func lineBreaksAndEdgeWhitespaceAreCanonicalized() {
    let transcript = WhisperKitTranscriber.transcript(segmentTexts: ["  one\r\ntwo  ", "\tthree\n"])

    #expect(transcript.text == "Speaker_1: one\ntwo\nSpeaker_1: three")
}

@Test func noSegmentsProduceAnEmptyTranscript() {
    let transcript = WhisperKitTranscriber.transcript(segmentTexts: [])

    #expect(transcript.text.isEmpty)
    #expect(transcript.utterances.isEmpty)
}

@Test func mappedRangesAreUTF8ByteRangesThatIncludeThePrefix() throws {
    let transcript = WhisperKitTranscriber.transcript(segmentTexts: [" café ☕", " naïve 🚀 plan"])

    let bytes = Array(transcript.text.utf8)
    #expect(transcript.utterances.count == 2)
    for utterance in transcript.utterances {
        let text = try #require(String(bytes: bytes[utterance.start ..< utterance.end], encoding: .utf8))
        #expect(text.hasPrefix("Speaker_1: "))
    }
    #expect(try #require(transcript.utterances.last).end == bytes.count)
}

@Test func decodeOptionsForceEnglishAndDisableEveryNonDeterministicPath() {
    let options = WhisperKitTranscriber.decodeOptions

    #expect(options.language == "en")
    #expect(!options.detectLanguage)
    #expect(options.usePrefillPrompt)
    #expect(options.skipSpecialTokens)
    #expect(options.temperature == 0)
    #expect(options.temperatureFallbackCount == 0)
    #expect(options.firstTokenLogProbThreshold == nil)
}

@Test func timingsFollowTheKeptUtterancesAndAreIndexedByTranscriptPosition() {
    let timed = WhisperKitTranscriber.timedTranscript(segments: [
        .init(text: " first", start: 0, end: 1.5),
        .init(text: "<|nospeech|>", start: 1.5, end: 2),
        .init(text: " second", start: 2, end: 4.25),
    ])

    #expect(timed.transcript.utterances.count == 2)
    #expect(timed.utteranceTimings == [
        UtteranceTiming(index: 0, startSeconds: 0, endSeconds: 1.5),
        UtteranceTiming(index: 1, startSeconds: 2, endSeconds: 4.25),
    ])
}

@Test func noSegmentsGiveAnEmptyTranscriptAndNoTimings() {
    let timed = WhisperKitTranscriber.timedTranscript(segments: [])

    #expect(timed.transcript.utterances.isEmpty)
    #expect(timed.utteranceTimings.isEmpty)
}
