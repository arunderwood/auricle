import Core

/// One speaker turn as an engine reports it, before labels, ids and derived
/// fields are assigned. `speaker` is the engine's own cluster id and means
/// nothing outside one run.
public struct RawSpeakerSegment: Sendable, Equatable {
    public let speaker: Int
    public let startSeconds: Double
    public let endSeconds: Double

    public init(speaker: Int, startSeconds: Double, endSeconds: Double) {
        self.speaker = speaker
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// Turns an engine's raw segments into the `DiarizationArtifact` every engine
/// must produce, so the invariants hold by construction: the same input gives
/// the same labels, ids and numbers.
public enum DiarizationArtifactBuilder {
    public static func build(raw: [RawSpeakerSegment], utteranceTimings: [UtteranceTiming]) -> DiarizationArtifact {
        let usable = raw
            .filter { $0.startSeconds.isFinite && $0.endSeconds.isFinite }
            .map { RawSpeakerSegment(speaker: $0.speaker, startSeconds: rounded($0.startSeconds), endSeconds: rounded($0.endSeconds)) }
            .filter { $0.endSeconds > $0.startSeconds }
            .sorted { lhs, rhs in
                (lhs.startSeconds, lhs.endSeconds, lhs.speaker) < (rhs.startSeconds, rhs.endSeconds, rhs.speaker)
            }

        var labels: [Int: String] = [:]
        for segment in usable where labels[segment.speaker] == nil {
            labels[segment.speaker] = "Speaker_\(labels.count + 1)"
        }

        let segments = usable.enumerated().map { offset, segment in
            DiarizationArtifact.Segment(
                id: "seg_\(offset + 1)",
                speakerLabel: labels[segment.speaker] ?? "Speaker_0",
                startSeconds: rounded(segment.startSeconds),
                endSeconds: rounded(segment.endSeconds),
                utteranceIndex: utteranceRange(of: segment, in: utteranceTimings),
                voiceProfile: DiarizationArtifact.VoiceProfile(overlapRatio: rounded(overlapRatio(of: segment, in: usable))),
            )
        }
        return DiarizationArtifact(segments: segments)
    }

    /// Milliseconds: finer than a diarizer can resolve, and a fixed precision
    /// keeps the written numbers from depending on float noise.
    private static func rounded(_ value: Double) -> Double {
        (value * 1000).rounded() / 1000
    }

    /// The share of `segment` covered by any other speaker's segment, with
    /// the covering intervals merged so two overlapping others count once.
    private static func overlapRatio(of segment: RawSpeakerSegment, in all: [RawSpeakerSegment]) -> Double {
        let clipped: [(Double, Double)] = all
            .filter { $0.speaker != segment.speaker }
            .compactMap { other in
                let start = max(other.startSeconds, segment.startSeconds)
                let end = min(other.endSeconds, segment.endSeconds)
                return end > start ? (start, end) : nil
            }
            .sorted { $0.0 < $1.0 }

        var covered = 0.0
        var current: (Double, Double)?
        for interval in clipped {
            if let open = current, interval.0 <= open.1 {
                current = (open.0, max(open.1, interval.1))
            } else {
                if let open = current {
                    covered += open.1 - open.0
                }
                current = interval
            }
        }
        if let open = current {
            covered += open.1 - open.0
        }

        let duration = segment.endSeconds - segment.startSeconds
        return min(max(covered / duration, 0), 1)
    }

    private static func utteranceRange(of segment: RawSpeakerSegment, in timings: [UtteranceTiming]) -> DiarizationArtifact.UtteranceRange? {
        let overlapping = timings.filter { $0.startSeconds < segment.endSeconds && $0.endSeconds > segment.startSeconds }.map(\.index)
        guard let first = overlapping.min(), let last = overlapping.max() else { return nil }
        return DiarizationArtifact.UtteranceRange(first: first, last: last)
    }
}
