import AIReviewerInterface
@testable import ClaudeAIReviewers
import Core
import DiarizerInterface
import Testing

struct DiarizationReviewPromptTests {
    private func segment(_ id: String, range: DiarizedUtteranceRange?) -> DiarizedSegment {
        DiarizedSegment(
            id: id,
            speakerLabel: "Speaker_1",
            startSeconds: 0,
            endSeconds: 1,
            utteranceIndex: range,
            voiceProfile: DiarizedVoiceProfile(overlapRatio: 0),
        )
    }

    private func render(text: String, utterances: [CanonicalTranscript.Utterance], segments: [DiarizedSegment]) -> String {
        DiarizationReviewPrompt.build(input: DiarizationReviewInput(
            transcript: CanonicalTranscript(text: text, utterances: utterances),
            diarization: DiarizationArtifact(segments: segments),
        )).meetingData
    }

    @Test("slices by UTF-8 byte offsets, not characters")
    func multibyte() {
        let text = "Speaker_1: héllo wörld"
        let byteCount = text.utf8.count
        let rendered = render(
            text: text,
            utterances: [.init(speakerLabel: "Speaker_1", start: 0, end: byteCount)],
            segments: [segment("seg_1", range: .init(first: 0, last: 0))],
        )
        #expect(rendered.contains("\nSpeaker_1: héllo wörld\n"))
    }

    @Test("a segment without utterances renders an empty body")
    func nilRange() {
        let rendered = render(text: "Speaker_1: hi", utterances: [.init(speakerLabel: "Speaker_1", start: 0, end: 13)], segments: [segment("seg_1", range: nil)])
        #expect(rendered.contains("overlap=0.00\n\n</meeting_data>"))
    }

    @Test("out-of-range or reversed offsets yield no text and do not trap")
    func invalidOffsets() {
        let utterances: [CanonicalTranscript.Utterance] = [.init(speakerLabel: "Speaker_1", start: 0, end: 999)]
        let outOfRangeEnd = render(text: "Speaker_1: hi", utterances: utterances, segments: [segment("seg_1", range: .init(first: 0, last: 0))])
        #expect(!outOfRangeEnd.contains("Speaker_1: hi"))
        let pastLast = render(text: "Speaker_1: hi", utterances: utterances, segments: [segment("seg_1", range: .init(first: 0, last: 5))])
        #expect(!pastLast.contains("Speaker_1: hi"))
        let reversed = render(text: "Speaker_1: hi", utterances: utterances, segments: [segment("seg_1", range: .init(first: 1, last: 0))])
        #expect(!reversed.contains("Speaker_1: hi"))
    }
}
