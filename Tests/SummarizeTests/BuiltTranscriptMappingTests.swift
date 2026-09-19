@testable import Core
@testable import Summarize
import Testing

/// The transcribe stage's transcripts are what the summarize stage reads, so
/// the prefix convention is pinned from both ends: a transcript built by
/// `CanonicalTranscriptBuilder` must come out of the summarize mapper's label
/// strip as the utterance text alone, for an attributed and an unattributed
/// speaker.
@Test func aBuiltTranscriptStripsToTheBareUtteranceTextForAnUnattributedSpeaker() throws {
    let transcript = CanonicalTranscriptBuilder.build([
        (speakerLabel: "Speaker_1", text: " We should ship on Friday. "),
        (speakerLabel: "Speaker_1", text: "café ☕ is closed\r\nuntil noon"),
    ])

    let segments = try SummaryArtifactMapper.transcriptSegments(
        of: transcript,
        transcriptBytes: Array(transcript.text.utf8),
        speakers: nil,
    )

    #expect(segments.map(\.text) == ["We should ship on Friday.", "café ☕ is closed\nuntil noon"])
    #expect(segments.map(\.speaker) == ["[[Speaker_1]]", "[[Speaker_1]]"])
}

@Test func aBuiltTranscriptStripsToTheBareUtteranceTextForAnAttributedSpeaker() throws {
    let transcript = CanonicalTranscriptBuilder.build([(speakerLabel: "Speaker_1", text: "Speaker_1: is quoted inside the text")])

    let segments = try SummaryArtifactMapper.transcriptSegments(
        of: transcript,
        transcriptBytes: Array(transcript.text.utf8),
        speakers: ["Speaker_1": "[[Ben]]"],
    )

    #expect(segments.map(\.text) == ["Speaker_1: is quoted inside the text"])
    #expect(segments.map(\.speaker) == ["[[Ben]]"])
}
