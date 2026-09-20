/// One proposed word or phrase correction, the entry type of
/// `transcription_suggestions.json`, which an `AIReviewerResult` wraps at
/// `schema_version` 1 so the concrete reviewer needs no migration. Nothing
/// writes the file until that reviewer exists.
public struct TranscriptionSuggestion: Suggestion, Equatable {
    public let suggestionId: String
    public let reasoning: String
    /// Where the text to replace sits in `transcript.json`'s text, as UTF-8
    /// byte offsets.
    public let charRange: ByteRange
    public let proposedReplacement: String

    enum CodingKeys: String, CodingKey {
        case suggestionId = "suggestion_id"
        case reasoning
        case charRange = "char_range"
        case proposedReplacement = "proposed_replacement"
    }

    public init(
        suggestionId: String,
        reasoning: String,
        charRange: ByteRange,
        proposedReplacement: String,
    ) {
        self.suggestionId = suggestionId
        self.reasoning = reasoning
        self.charRange = charRange
        self.proposedReplacement = proposedReplacement
    }
}
