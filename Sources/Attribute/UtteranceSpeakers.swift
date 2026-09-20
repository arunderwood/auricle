import Core
import DiarizerInterface

/// Which speaker each transcript utterance belongs to, joined from the
/// immutable `diarization.json` and the corrections in `attribution.json`.
///
/// `transcript.json` labels every utterance with the same placeholder, so the
/// utterance's own label says nothing about who spoke. The join key is a
/// segment's `utterance_index`. The names come from `renderTranscript`, so a
/// note and the attribution view resolve a segment identically.
public enum UtteranceSpeakers {
    /// True for `Speaker_<digits>`: the placeholder for a speaker nobody has
    /// named.
    public static func isPlaceholder(_ value: String) -> Bool {
        SpeakerNaming.isPlaceholder(value)
    }

    /// One entry per utterance, `[[Name]]` or a `Speaker_N` placeholder. `nil`
    /// when no segment covers the utterance, or when the segments covering it
    /// disagree. A split divides a segment by time and an utterance carries no
    /// time, so an utterance inside a split that gives its parts different
    /// speakers has no single speaker to name.
    public static func resolve(
        utteranceCount: Int,
        diarization: DiarizationArtifact,
        file: AttributionFile?,
    ) -> [String?] {
        let rendered = renderTranscript(
            diarization: diarization,
            overrides: file?.segmentOverrides ?? [],
            splits: file?.segmentSplits ?? [],
            speakers: file?.speakers ?? [:],
        )
        var speakers = [String?](repeating: nil, count: utteranceCount)
        var disputed = Set<Int>()
        for segment in rendered.segments {
            guard let range = segment.utteranceIndex, range.first <= range.last else { continue }
            let low = max(range.first, 0)
            let high = min(range.last, utteranceCount - 1)
            guard low <= high else { continue }
            for index in low ... high {
                guard !disputed.contains(index) else { continue }
                if let existing = speakers[index], existing != segment.speakerLabel {
                    speakers[index] = nil
                    disputed.insert(index)
                } else {
                    speakers[index] = segment.speakerLabel
                }
            }
        }
        return speakers
    }
}
