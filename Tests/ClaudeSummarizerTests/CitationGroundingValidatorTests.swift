@testable import ClaudeSummarizer
import Core
import SummarizerInterface
import Testing

/// Builds byte offsets programmatically from each utterance's own text
/// rather than hand-computing them, so this fixture can't drift from the
/// transcript text it's supposed to describe.
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

// MARK: - Valid range

@Test func validSingleUtteranceRangeReturnsAGroundingPointerMatchingThatUtterance() throws {
    let transcript = makeTranscript(utteranceTexts: ["First utterance.", "Second utterance.", "Third utterance."])

    let pointer = try CitationGroundingValidator.validate(
        citation: CitationBlockLocation(startBlockIndex: 1, endBlockIndex: 2),
        in: transcript,
    )

    #expect(pointer == GroundingPointer(
        transcriptStart: transcript.utterances[1].start,
        transcriptEnd: transcript.utterances[1].end,
        sourceMethod: .citations,
    ))
}

// MARK: - start < 0

@Test func negativeStartBlockIndexThrowsMalformedResponse() {
    let transcript = makeTranscript(utteranceTexts: ["First.", "Second."])

    #expect(throws: SummarizerError.malformedResponse) {
        try CitationGroundingValidator.validate(
            citation: CitationBlockLocation(startBlockIndex: -1, endBlockIndex: 1),
            in: transcript,
        )
    }
}

// MARK: - end > utteranceCount

@Test func endBlockIndexPastUtteranceCountThrowsMalformedResponse() {
    let transcript = makeTranscript(utteranceTexts: ["First.", "Second."])

    #expect(throws: SummarizerError.malformedResponse) {
        try CitationGroundingValidator.validate(
            citation: CitationBlockLocation(startBlockIndex: 0, endBlockIndex: 3),
            in: transcript,
        )
    }
}

// MARK: - start >= end

@Test func startNotLessThanEndThrowsMalformedResponse() {
    let transcript = makeTranscript(utteranceTexts: ["First.", "Second."])

    #expect(throws: SummarizerError.malformedResponse) {
        try CitationGroundingValidator.validate(
            citation: CitationBlockLocation(startBlockIndex: 1, endBlockIndex: 1),
            in: transcript,
        )
    }
}

// MARK: - Multi-utterance span

@Test func multiUtteranceSpanCoversFromTheFirstUtterancesStartToTheLastUtterancesEnd() throws {
    let transcript = makeTranscript(utteranceTexts: ["First utterance.", "Second utterance.", "Third utterance."])

    let pointer = try CitationGroundingValidator.validate(
        citation: CitationBlockLocation(startBlockIndex: 0, endBlockIndex: 3),
        in: transcript,
    )

    #expect(pointer.transcriptStart == transcript.utterances[0].start)
    #expect(pointer.transcriptEnd == transcript.utterances[2].end)
    #expect(pointer.sourceMethod == .citations)
}
