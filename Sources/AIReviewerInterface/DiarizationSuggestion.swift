/// A replacement sub-segment, in seconds from the start of the audio.
public struct ProposedSplit: Codable, Sendable, Equatable {
    public let start: Double
    public let end: Double
    public let speakerLabel: String

    enum CodingKeys: String, CodingKey {
        case start
        case end
        case speakerLabel = "speaker_label"
    }

    public init(start: Double, end: Double, speakerLabel: String) {
        self.start = start
        self.end = end
        self.speakerLabel = speakerLabel
    }
}

/// One flagged diarization segment, the entry type of
/// `diarization_suggestions.json`.
public struct DiarizationSuggestion: Suggestion, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        /// Two speakers labeled as one.
        case underSegmentation = "under_segmentation"
        /// One speaker labeled as two.
        case overSegmentation = "over_segmentation"
    }

    public let suggestionId: String
    public let reasoning: String
    public let kind: Kind
    /// The `diarization.json` segment the suggestion is about.
    public let segmentId: String
    /// Empty for an over-segmentation suggestion, which proposes a merge.
    public let proposedSplits: [ProposedSplit]

    enum CodingKeys: String, CodingKey {
        case suggestionId = "suggestion_id"
        case reasoning
        case kind
        case segmentId = "segment_id"
        case proposedSplits = "proposed_splits"
    }

    public init(
        suggestionId: String,
        reasoning: String,
        kind: Kind,
        segmentId: String,
        proposedSplits: [ProposedSplit],
    ) {
        self.suggestionId = suggestionId
        self.reasoning = reasoning
        self.kind = kind
        self.segmentId = segmentId
        self.proposedSplits = proposedSplits
    }
}
