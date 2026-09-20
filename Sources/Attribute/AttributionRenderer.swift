import Core
import DiarizerInterface
import Foundation

/// One entry of the rendered transcript: a `diarization.json` segment, or a
/// sub-segment a split replaced it with.
public struct RenderedSegment: Equatable, Sendable {
    /// The original segment id, or `<original>.<n>` for a split's sub-segment.
    public let id: String
    public let startSeconds: Double
    public let endSeconds: Double
    /// `[[Name]]`, or the `Speaker_N` placeholder.
    public let speakerLabel: String
    /// The parent's utterances with the speaker prefix removed. Empty for a
    /// sub-segment, because utterances carry no timing to divide them by, and
    /// empty when no transcript was given.
    public let text: String
    /// `nil` when the speaker came from the default map.
    public let appliedFrom: AttributionSource?

    public init(id: String, startSeconds: Double, endSeconds: Double, speakerLabel: String, text: String, appliedFrom: AttributionSource?) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.speakerLabel = speakerLabel
        self.text = text
        self.appliedFrom = appliedFrom
    }
}

public struct RenderedTranscript: Equatable, Sendable {
    /// Ordered by start time; equal starts keep `diarization.json` order.
    public let segments: [RenderedSegment]

    public init(segments: [RenderedSegment]) {
        self.segments = segments
    }
}

/// Composes what the user sees from the immutable `diarization.json` and the
/// corrections in `attribution.json`. Pure: no I/O, same output for the same
/// input.
///
/// Resolution order per segment: a split replacing it, then a per-segment
/// override, then the `speakers` map, then the `Speaker_N` label. A split or
/// override naming a segment that `diarization` does not have is ignored. With
/// several entries for one segment, the first split and the last override win.
public func renderTranscript(
    diarization: DiarizationArtifact,
    overrides: [SegmentOverride],
    splits: [SegmentSplit],
    speakers: [String: String],
    transcript: CanonicalTranscript? = nil,
) -> RenderedTranscript {
    var splitsByID: [String: SegmentSplit] = [:]
    for split in splits where splitsByID[split.originalSegmentId] == nil {
        splitsByID[split.originalSegmentId] = split
    }
    let overridesByID = Dictionary(overrides.map { ($0.segmentId, $0.speaker) }, uniquingKeysWith: { _, last in last })

    var rendered: [RenderedSegment] = []
    for segment in diarization.segments {
        if let split = splitsByID[segment.id] {
            for (index, part) in split.splits.enumerated() {
                rendered.append(RenderedSegment(
                    id: part.newId.isEmpty ? "\(segment.id).\(index)" : part.newId,
                    startSeconds: part.start,
                    endSeconds: part.end,
                    speakerLabel: nonBlank(part.speaker) ?? segment.speakerLabel,
                    text: "",
                    appliedFrom: split.source,
                ))
            }
            continue
        }
        let text = transcript.map { utteranceText(of: segment, in: $0) } ?? ""
        if let override = overridesByID[segment.id].flatMap(nonBlank) {
            rendered.append(RenderedSegment(
                id: segment.id, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds,
                speakerLabel: override, text: text, appliedFrom: .manual,
            ))
        } else {
            rendered.append(RenderedSegment(
                id: segment.id, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds,
                speakerLabel: speakers[segment.speakerLabel].flatMap(nonBlank) ?? segment.speakerLabel,
                text: text, appliedFrom: nil,
            ))
        }
    }

    let ordered = rendered.enumerated()
        .sorted { ($0.element.startSeconds, $0.offset) < ($1.element.startSeconds, $1.offset) }
        .map(\.element)
    return RenderedTranscript(segments: ordered)
}

private func nonBlank(_ value: String) -> String? {
    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
}

/// The segment's utterances, one per line, each with exactly one
/// `<Speaker_N>: ` prefix removed. An index range outside the transcript
/// yields the utterances that do exist.
private func utteranceText(of segment: DiarizedSegment, in transcript: CanonicalTranscript) -> String {
    guard let range = segment.utteranceIndex, range.first <= range.last else { return "" }
    let bytes = Array(transcript.text.utf8)
    var lines: [String] = []
    for index in range.first ... range.last where transcript.utterances.indices.contains(index) {
        let utterance = transcript.utterances[index]
        guard utterance.start >= 0, utterance.start <= utterance.end, utterance.end <= bytes.count else { continue }
        var start = utterance.start
        let prefix = Array("\(utterance.speakerLabel): ".utf8)
        if utterance.end - start >= prefix.count, Array(bytes[start ..< start + prefix.count]) == prefix {
            start += prefix.count
        } else if utterance.end - start == prefix.count - 1, Array(bytes[start ..< utterance.end]) == Array(prefix.dropLast()) {
            start = utterance.end
        }
        lines.append(String(bytes: bytes[start ..< utterance.end], encoding: .utf8) ?? "")
    }
    return lines.joined(separator: "\n")
}
