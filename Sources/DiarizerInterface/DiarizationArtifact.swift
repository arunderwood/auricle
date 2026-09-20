/// Both ends are inclusive indices into `CanonicalTranscript.utterances`.
public struct DiarizedUtteranceRange: Codable, Sendable, Equatable {
    public let first: Int
    public let last: Int

    public init(first: Int, last: Int) {
        self.first = first
        self.last = last
    }

    enum CodingKeys: String, CodingKey {
        case first
        case last
    }
}

/// The variance signal the attribution sheet warns on. SpeakerKit exposes
/// per-speaker centroid embeddings but no per-segment ones, so the share
/// of a segment that another speaker also covers stands in for it.
public struct DiarizedVoiceProfile: Codable, Sendable, Equatable {
    public let overlapRatio: Double

    public init(overlapRatio: Double) {
        self.overlapRatio = overlapRatio
    }

    enum CodingKeys: String, CodingKey {
        case overlapRatio = "overlap_ratio"
    }
}

public struct DiarizedSegment: Codable, Sendable, Equatable {
    public let id: String
    public let speakerLabel: String
    public let startSeconds: Double
    public let endSeconds: Double
    /// The utterances this segment overlaps; `nil` when no timing was
    /// available or none overlaps.
    public let utteranceIndex: DiarizedUtteranceRange?
    public let voiceProfile: DiarizedVoiceProfile

    public init(
        id: String,
        speakerLabel: String,
        startSeconds: Double,
        endSeconds: Double,
        utteranceIndex: DiarizedUtteranceRange?,
        voiceProfile: DiarizedVoiceProfile,
    ) {
        self.id = id
        self.speakerLabel = speakerLabel
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.utteranceIndex = utteranceIndex
        self.voiceProfile = voiceProfile
    }

    enum CodingKeys: String, CodingKey {
        case id
        case speakerLabel = "speaker_label"
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
        case utteranceIndex = "utterance_index"
        case voiceProfile = "voice_profile"
    }
}

/// The contents of `diarization.json`: who spoke when, before any human or AI
/// correction. It is immutable once written. Corrections live in other
/// artifacts that reference these segments by id.
///
/// Speaker labels are `Speaker_<n>` in order of first appearance, and segment
/// ids are `seg_<n>` in start-time order, both counting from 1.
public struct DiarizationArtifact: Codable, Sendable, Equatable {
    public typealias UtteranceRange = DiarizedUtteranceRange
    public typealias VoiceProfile = DiarizedVoiceProfile
    public typealias Segment = DiarizedSegment

    public let segments: [Segment]

    public init(segments: [Segment]) {
        self.segments = segments
    }

    enum CodingKeys: String, CodingKey {
        case segments
    }

    /// In order of first appearance.
    public var speakerLabels: [String] {
        var seen = Set<String>()
        return segments.map(\.speakerLabel).filter { seen.insert($0).inserted }
    }
}
