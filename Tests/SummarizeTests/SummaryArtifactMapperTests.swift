import Core
@testable import Summarize
import SummarizerInterface
import Testing

private let text = "Speaker_1: café time\nSpeaker_2: 🚀 go"
private let bytes = Array(text.utf8)
private let firstEnd = "Speaker_1: café time".utf8.count

private let transcript = CanonicalTranscript(text: text, utterances: [
    .init(speakerLabel: "Speaker_1", start: 0, end: firstEnd),
    .init(speakerLabel: "Speaker_2", start: firstEnd + 1, end: bytes.count),
])

// MARK: - needsAttribution

@Test func needsAttributionIsTrueWhenThereIsNoAttributionFile() {
    #expect(SummaryArtifactMapper.needsAttribution(transcript: transcript, speakers: nil))
}

@Test func needsAttributionIsFalseOnlyWhenEveryDistinctSpeakerIsMapped() {
    let both = ["Speaker_1": "[[Ada]]", "Speaker_2": "[[Ben]]"]
    let one = ["Speaker_1": "[[Ada]]"]
    let extra = both.merging(["Speaker_9": "[[Cy]]"]) { first, _ in first }

    #expect(!SummaryArtifactMapper.needsAttribution(transcript: transcript, speakers: both))
    #expect(SummaryArtifactMapper.needsAttribution(transcript: transcript, speakers: one))
    #expect(SummaryArtifactMapper.needsAttribution(transcript: transcript, speakers: [:]))
    #expect(!SummaryArtifactMapper.needsAttribution(transcript: transcript, speakers: extra))
}

@Test func aSpeakerWhoSpokeTwiceIsOneDistinctLabel() {
    let repeated = CanonicalTranscript(text: "a b c", utterances: [
        .init(speakerLabel: "Speaker_1", start: 0, end: 1),
        .init(speakerLabel: "Speaker_2", start: 2, end: 3),
        .init(speakerLabel: "Speaker_1", start: 4, end: 5),
    ])

    #expect(!SummaryArtifactMapper.needsAttribution(transcript: repeated, speakers: ["Speaker_1": "[[A]]", "Speaker_2": "[[B]]"]))
}

// MARK: - transcriptSegments

@Test func segmentsCarryTheUtteranceTextWithoutItsLeadingLabelAndTheMappedOrPlaceholderSpeaker() throws {
    let segments = try SummaryArtifactMapper.transcriptSegments(
        of: transcript,
        transcriptBytes: bytes,
        speakers: ["Speaker_2": "[[Ben]]"],
    )

    #expect(segments == [
        TranscriptSegmentArtifact(speaker: "[[Speaker_1]]", text: "café time"),
        TranscriptSegmentArtifact(speaker: "[[Ben]]", text: "🚀 go"),
    ])
}

@Test func onlyTheUtterancesOwnLeadingLabelIsDropped() throws {
    let lines = [
        "Speaker_1: I told Speaker_2: hi",
        "Speaker_2: Speaker_1: is what she said",
        "Speaker_1: Speaker_1: said twice",
        "Speaker_1: Speaker_10: not a prefix of the label",
    ]
    let text = lines.joined(separator: "\n")
    let bytes = Array(text.utf8)
    let labels = ["Speaker_1", "Speaker_2", "Speaker_1", "Speaker_1"]
    var offset = 0
    var utterances: [CanonicalTranscript.Utterance] = []
    for (label, line) in zip(labels, lines) {
        utterances.append(.init(speakerLabel: label, start: offset, end: offset + line.utf8.count))
        offset += line.utf8.count + 1
    }

    let segments = try SummaryArtifactMapper.transcriptSegments(
        of: CanonicalTranscript(text: text, utterances: utterances),
        transcriptBytes: bytes,
        speakers: nil,
    )

    #expect(segments.map(\.text) == [
        "I told Speaker_2: hi",
        "Speaker_1: is what she said",
        "Speaker_1: said twice",
        "Speaker_10: not a prefix of the label",
    ])
}

@Test func aRangeThatAlreadyExcludesTheLabelIsLeftAsIs() throws {
    let text = "Speaker_1: hello\nSpeaker_2: hi"
    let bytes = Array(text.utf8)
    let bodyStart = "Speaker_1: ".utf8.count
    let secondBodyStart = "Speaker_1: hello\nSpeaker_2: ".utf8.count
    let bare = CanonicalTranscript(text: text, utterances: [
        .init(speakerLabel: "Speaker_1", start: bodyStart, end: bodyStart + "hello".utf8.count),
        .init(speakerLabel: "Speaker_2", start: secondBodyStart, end: bytes.count),
    ])

    let segments = try SummaryArtifactMapper.transcriptSegments(of: bare, transcriptBytes: bytes, speakers: nil)

    #expect(segments.map(\.text) == ["hello", "hi"])
}

@Test func anUtteranceThatIsOnlyItsLabelHasNoText() throws {
    let text = "Speaker_1:\nSpeaker_2: hi"
    let firstEnd = "Speaker_1:".utf8.count
    let transcript = CanonicalTranscript(text: text, utterances: [
        .init(speakerLabel: "Speaker_1", start: 0, end: firstEnd),
        .init(speakerLabel: "Speaker_2", start: firstEnd + 1, end: text.utf8.count),
    ])

    let segments = try SummaryArtifactMapper.transcriptSegments(of: transcript, transcriptBytes: Array(text.utf8), speakers: nil)

    #expect(segments.map(\.text) == ["", "hi"])
}

@Test func aLabelFollowedByACombiningMarkStillLosesItsPrefix() throws {
    let text = "Speaker_1: \u{301}odd"
    let transcript = CanonicalTranscript(text: text, utterances: [
        .init(speakerLabel: "Speaker_1", start: 0, end: text.utf8.count),
    ])

    let segments = try SummaryArtifactMapper.transcriptSegments(of: transcript, transcriptBytes: Array(text.utf8), speakers: nil)

    #expect(segments.map(\.text) == ["\u{301}odd"])
}

@Test func anUtteranceOutsideTheTranscriptThrowsSegmentExtractionFailed() {
    let bad = CanonicalTranscript(text: "abc", utterances: [.init(speakerLabel: "Speaker_1", start: 0, end: 4)])

    #expect(throws: SummarizeStageError.segmentExtractionFailed) {
        try SummaryArtifactMapper.transcriptSegments(of: bad, transcriptBytes: Array("abc".utf8), speakers: nil)
    }
}

// MARK: - artifact

private func grounded(actionRange: (Int, Int)) -> SummaryWithGrounding {
    let pointer = GroundingPointer(transcriptStart: actionRange.0, transcriptEnd: actionRange.1, sourceMethod: .substring)
    return SummaryWithGrounding(
        schemaVersion: 1,
        summary: "s",
        actionItems: [GroundedItem(text: "do it", grounding: pointer)],
        decisions: [],
        groundingMethod: .substring,
        cost: SummarizerCost(inputTokens: 1, outputTokens: 1, thinkingTokens: 0, costUSD: 0),
        quoteValidationDropCount: 0,
    )
}

@Test func artifactQuotesAreTheByteSliceAndTheCalendarFieldsAreUnenriched() throws {
    let start = "Speaker_1: ".utf8.count
    let artifact = try SummaryArtifactMapper.artifact(
        title: "Meeting at X",
        grounded: grounded(actionRange: (start, start + "café".utf8.count)),
        transcriptSegments: [],
        needsAttribution: true,
        transcriptBytes: bytes,
    )

    #expect(artifact.actionItems == [QuotedItemArtifact(text: "do it", quote: "café")])
    #expect(artifact.title == "Meeting at X")
    #expect(artifact.calendarEventTitle == nil)
    #expect(artifact.attendees.isEmpty)
    #expect(artifact.selfWikilink == nil)
    #expect(artifact.needsCalendarEnrichment)
}

@Test func anOutOfRangePointerThrowsQuoteExtractionFailed() {
    #expect(throws: SummarizeStageError.quoteExtractionFailed) {
        try SummaryArtifactMapper.artifact(
            title: "t",
            grounded: grounded(actionRange: (0, bytes.count + 1)),
            transcriptSegments: [],
            needsAttribution: true,
            transcriptBytes: bytes,
        )
    }
}
