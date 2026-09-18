import Core
import SummarizerInterface

/// A citation's block-index bounds exactly as Anthropic reports them on a
/// `content_block_location` object: zero-indexed, `endBlockIndex` exclusive.
public struct CitationBlockLocation: Sendable, Equatable {
    public let startBlockIndex: Int
    public let endBlockIndex: Int

    public init(startBlockIndex: Int, endBlockIndex: Int) {
        self.startBlockIndex = startBlockIndex
        self.endBlockIndex = endBlockIndex
    }
}

/// Bounds-checked block-index grounding: the Citations counterpart to
/// `SubstringGroundingValidator`. Throws instead of returning `nil` —
/// deliberately asymmetric with `SubstringGroundingValidator`'s nil-
/// returning shape, since "not found" isn't expressible for a bounds-checked
/// index the same way it is for a substring search: an out-of-range index
/// means the response doesn't describe the document auricle actually sent,
/// which is a malformed response, not an absence (Decision 3.4).
public enum CitationGroundingValidator {
    /// Well-formed Citations responses always pass: auricle segmented the
    /// document itself, so a block index is valid by construction when the
    /// response describes what was sent — there is no encoding-convention
    /// gap here the way there is for a character offset.
    ///
    /// - Throws: `SummarizerError.malformedResponse` when `citation`'s
    ///   bounds don't describe a valid, non-empty range of `transcript`'s
    ///   utterances (`startBlockIndex < 0`, `endBlockIndex` past
    ///   `transcript.utteranceCount`, or `startBlockIndex >= endBlockIndex`).
    public static func validate(citation: CitationBlockLocation, in transcript: CanonicalTranscript) throws -> GroundingPointer {
        guard
            citation.startBlockIndex >= 0,
            citation.endBlockIndex <= transcript.utteranceCount,
            citation.startBlockIndex < citation.endBlockIndex
        else {
            throw SummarizerError.malformedResponse
        }

        let startUtterance = transcript.utterances[citation.startBlockIndex]
        let endUtterance = transcript.utterances[citation.endBlockIndex - 1]
        return GroundingPointer(
            transcriptStart: startUtterance.start,
            transcriptEnd: endUtterance.end,
            sourceMethod: .citations,
        )
    }
}
