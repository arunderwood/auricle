import Core
import SummarizerInterface

/// Literal, case-sensitive substring grounding: the non-Citations path used
/// by both `ClaudeSubstringSummarizer` (this story) and the v1.1+ local-LLM
/// strategy FR33 requires (Decision 3.2). Stateless by design — a namespace,
/// not a value with configuration, matching `SummarizationPromptBuilder`'s
/// own shape.
public enum SubstringGroundingValidator {
    /// Searches `transcript.text` for `quote` verbatim. Doesn't throw:
    /// "not found" is a signal, not an error — the caller decides what it
    /// means (this story's caller drops the item; a future caller could
    /// choose differently).
    ///
    /// - Returns: A `GroundingPointer` with UTF-8 byte offsets when `quote`
    ///   occurs in `transcript.text`, using the first match when it occurs
    ///   more than once (there is no signal in the model's response to
    ///   disambiguate); `nil` when it doesn't occur at all.
    public static func validate(quote: String, in transcript: CanonicalTranscript) -> GroundingPointer? {
        guard let range = transcript.text.range(of: quote) else {
            return nil
        }

        let utf8 = transcript.text.utf8
        // A `String.Index` from `range(of:)` always sits on a grapheme-
        // cluster boundary, and every grapheme-cluster boundary is also a
        // valid UTF-8 boundary, so `samePosition(in:)` cannot fail here —
        // the `guard` still exists because `nil` is the type-correct way to
        // express "not found" from this function, not because failure is
        // expected.
        guard
            let lowerUTF8 = range.lowerBound.samePosition(in: utf8),
            let upperUTF8 = range.upperBound.samePosition(in: utf8)
        else {
            return nil
        }

        return GroundingPointer(
            transcriptStart: utf8.distance(from: utf8.startIndex, to: lowerUTF8),
            transcriptEnd: utf8.distance(from: utf8.startIndex, to: upperUTF8),
            sourceMethod: .substring,
        )
    }
}
