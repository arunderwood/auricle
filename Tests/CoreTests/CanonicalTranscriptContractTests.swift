@testable import ClaudeSummarizer
@testable import Core
import Foundation
import SummarizerInterface
import Testing

/// Decision 3.4's build-time canonicalization invariant: extends
/// `CanonicalTranscriptTests.swift`'s Story 3.1 round-trip test with the
/// three properties that guard against `CitationGroundingValidator` and
/// `SubstringGroundingValidator` silently disagreeing about what a character
/// offset means. Deliberately internal-only: these fixtures assert
/// consistency among already-well-formed values, not that a real transcript
/// happens to be NFC/LF-normalized (that enforcement is the transcribe
/// stage's job, not yet built).
///
/// Byte offsets are built programmatically from each utterance's own text
/// rather than hand-computed, so a fixture here can't itself drift from the
/// transcript text it's supposed to describe — the exact class of bug this
/// invariant exists to catch.
private func makeTranscript(utteranceTexts: [String]) -> CanonicalTranscript {
    var text = ""
    var utterances: [CanonicalTranscript.Utterance] = []
    for (index, utteranceText) in utteranceTexts.enumerated() {
        if index > 0 {
            text += "\n"
        }
        let start = text.utf8.count
        text += utteranceText
        utterances.append(CanonicalTranscript.Utterance(speakerLabel: "Speaker_\(index + 1)", start: start, end: text.utf8.count))
    }
    return CanonicalTranscript(text: text, utterances: utterances)
}

// MARK: - (a) Round-trip byte-identical text

@Test func canonicalTranscriptJSONRoundTripProducesByteIdenticalText() throws {
    let transcript = makeTranscript(utteranceTexts: ["café standup notes.", "Ben will draft the brief by Friday."])

    let data = try JSONEncoder().encode(transcript)
    let decoded = try JSONDecoder().decode(CanonicalTranscript.self, from: data)

    #expect(Array(decoded.text.utf8) == Array(transcript.text.utf8))
}

// MARK: - (b) Citations segmentation matches CanonicalTranscript's own utterance ranges

@Test func contentBlockTextsMatchesEachUtterancesOwnByteSliceExactly() throws {
    let transcript = makeTranscript(utteranceTexts: [
        "café standup notes.",
        "Ben will draft the brief by Friday.",
        "Priya pushes the launch to the 15th.",
    ])

    let blocks = ClaudeCitationsSummarizer.contentBlockTexts(for: transcript)

    #expect(blocks.count == transcript.utterances.count)
    let bytes = Array(transcript.text.utf8)
    for (block, utterance) in zip(blocks, transcript.utterances) {
        let expected = try #require(String(bytes: bytes[utterance.start ..< utterance.end], encoding: .utf8))
        #expect(block == expected)
    }
}

// MARK: - Out-of-bounds utterance range degrades to empty text instead of crashing

@Test func contentBlockTextsReturnsEmptyStringForAnUtteranceRangePastTheTranscriptsByteCount() {
    let transcript = makeTranscript(utteranceTexts: ["café standup notes."])
    let outOfBoundsUtterance = CanonicalTranscript.Utterance(
        speakerLabel: "Speaker_2",
        start: 0,
        end: transcript.text.utf8.count + 50,
    )
    let transcriptWithOutOfBoundsUtterance = CanonicalTranscript(
        text: transcript.text,
        utterances: transcript.utterances + [outOfBoundsUtterance],
    )

    let blocks = ClaudeCitationsSummarizer.contentBlockTexts(for: transcriptWithOutOfBoundsUtterance)

    #expect(blocks.count == 2)
    #expect(blocks[1] == "")
}

// MARK: - (c) Substring and Citations validators agree on the same character space

@Test func substringAndCitationValidatorsAgreeOnTheSameUtterancesByteRange() throws {
    let transcript = makeTranscript(utteranceTexts: ["café standup notes.", "Ben will draft the brief by Friday."])
    let utteranceIndex = 0
    let utterance = transcript.utterances[utteranceIndex]
    let quote = try #require(String(bytes: Array(transcript.text.utf8)[utterance.start ..< utterance.end], encoding: .utf8))

    let substringPointer = try #require(SubstringGroundingValidator.validate(quote: quote, in: transcript))
    let citationPointer = try CitationGroundingValidator.validate(
        citation: CitationBlockLocation(startBlockIndex: utteranceIndex, endBlockIndex: utteranceIndex + 1),
        in: transcript,
    )

    // `sourceMethod` necessarily differs (`.substring` vs. `.citations`) —
    // the invariant under test is that both validators resolve the same
    // underlying utterance to the same byte range, not full `Equatable`
    // equality of the two pointers.
    #expect(substringPointer.transcriptStart == citationPointer.transcriptStart)
    #expect(substringPointer.transcriptEnd == citationPointer.transcriptEnd)
}
