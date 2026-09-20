import AIReviewerInterface
import Core
import DiarizerInterface
import Foundation

/// The three text blocks of a diarization review call. Kept apart from the
/// transport so the wording can change without touching request assembly.
struct DiarizationReviewPrompt: Equatable {
    let system: String
    let instructions: String
    let meetingData: String

    static let systemText = """
    You review speaker diarization for meeting transcripts. A diarizer has split \
    the audio into segments and labeled each with a speaker. You judge whether \
    those labels look wrong, using only the transcript text and the segment \
    metadata you are given. You never rewrite the transcript.
    """

    static let instructionsText = """
    Flag a segment only when the evidence in its text and metadata is concrete.

    Two kinds of flag exist:
    - "under_segmentation": one segment contains more than one speaker. Include \
    "proposed_splits", each with "start" and "end" in seconds from the start of \
    the audio and a "speaker_label" that is one of the labels already in use.
    - "over_segmentation": one real speaker was split across two labels. Leave \
    "proposed_splits" as an empty array.

    Answer with a single JSON object and nothing else:
    {"suggestions": [{"segment_id": "seg_1", "kind": "under_segmentation", \
    "reasoning": "one sentence", "proposed_splits": [{"start": 0.0, "end": 1.0, \
    "speaker_label": "Speaker_1"}]}]}

    Each segment line shows "overlap", the share of that segment another \
    speaker also covers; a high value is weak evidence of two voices.

    Use only segment ids that appear in the meeting data. If nothing looks \
    wrong, answer {"suggestions": []}.
    """

    static func build(input: DiarizationReviewInput) -> DiarizationReviewPrompt {
        DiarizationReviewPrompt(
            system: systemText,
            instructions: instructionsText,
            meetingData: renderMeetingData(input: input),
        )
    }

    private static func renderMeetingData(input: DiarizationReviewInput) -> String {
        var lines = ["<meeting_data>"]
        let utf8 = Array(input.transcript.text.utf8)
        for segment in input.diarization.segments {
            lines.append(renderSegment(segment, transcript: input.transcript, utf8: utf8))
        }
        lines.append("</meeting_data>")
        return lines.joined(separator: "\n")
    }

    private static func renderSegment(_ segment: DiarizedSegment, transcript: CanonicalTranscript, utf8: [UInt8]) -> String {
        let start = String(format: "%.2f", segment.startSeconds)
        let end = String(format: "%.2f", segment.endSeconds)
        let overlap = String(format: "%.2f", segment.voiceProfile.overlapRatio)
        let header = "[\(segment.id)] label=\(segment.speakerLabel) start=\(start)s end=\(end)s overlap=\(overlap)"
        return "\(header)\n\(text(of: segment, in: transcript, utf8: utf8))"
    }

    /// Utterance ranges are UTF-8 byte offsets, so slicing goes through the
    /// UTF-8 view; an out-of-range or mid-scalar offset yields no text rather
    /// than trapping on a malformed artifact.
    private static func text(of segment: DiarizedSegment, in transcript: CanonicalTranscript, utf8: [UInt8]) -> String {
        guard let range = segment.utteranceIndex else { return "" }
        let utterances = transcript.utterances
        guard range.first >= 0, range.first <= range.last, range.last < utterances.count else { return "" }
        return utterances[range.first ... range.last].compactMap { utterance -> String? in
            guard utterance.start >= 0, utterance.start <= utterance.end, utterance.end <= utf8.count else { return nil }
            return String(bytes: utf8[utterance.start ..< utterance.end], encoding: .utf8)
        }.joined(separator: "\n")
    }
}
