import Core

/// The Phase 1 sibling of the AI-reviewer family (Decision 5.1) that fixes
/// mistranscribed vault jargon in a summary. It takes a finished draft and
/// the glossary and answers with what it corrected; it never edits the
/// summary itself.
public protocol JargonCorrectionStrategy: Sendable {
    func correct(summary: SummaryDraft, glossary: Glossary) async throws -> [JargonCorrection]
}

/// What a jargon correction reads: the summary text and the transcript text
/// it was written from. No `Meeting` and no grounding pointers, so a strategy
/// sees only what it needs to compare the two.
public struct SummaryDraft: Sendable, Equatable {
    public let summaryText: String
    public let transcriptText: String

    public init(summaryText: String, transcriptText: String) {
        self.summaryText = summaryText
        self.transcriptText = transcriptText
    }
}

/// A half-open UTF-8 byte range into a text, the offset convention every
/// range in the pipeline uses (`GroundingPointer`, `CanonicalTranscript`).
public struct ByteRange: Codable, Sendable, Equatable {
    /// Inclusive.
    public let start: Int
    /// Exclusive.
    public let end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    enum CodingKeys: String, CodingKey {
        case start
        case end
    }
}

/// One glossary term the summary spells correctly where the transcript
/// spelled it another way. `suggestionId` and `reasoning` are the two members
/// the suggestion family shares, so the review UI can adopt this type without
/// a change to it.
public struct JargonCorrection: Codable, Sendable, Equatable {
    /// Deterministic for a given summary and glossary, and unique within one
    /// result.
    public let suggestionId: String
    public let reasoning: String
    /// Where `correctedSpan` sits in the summary text.
    public let charRange: ByteRange
    /// The transcript's spelling.
    public let originalSpan: String
    /// The summary's spelling, equal to the summary text at `charRange`.
    public let correctedSpan: String

    enum CodingKeys: String, CodingKey {
        case suggestionId = "suggestion_id"
        case reasoning
        case charRange = "char_range"
        case originalSpan = "original_span"
        case correctedSpan = "corrected_span"
    }

    public init(
        suggestionId: String,
        reasoning: String,
        charRange: ByteRange,
        originalSpan: String,
        correctedSpan: String,
    ) {
        self.suggestionId = suggestionId
        self.reasoning = reasoning
        self.charRange = charRange
        self.originalSpan = originalSpan
        self.correctedSpan = correctedSpan
    }
}
