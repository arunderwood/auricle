import AIReviewerInterface
import Core
import Foundation
import VaultGlossary

/// The MVP `JargonCorrectionStrategy`: it makes no API call. The summary
/// already went through the model with the scoped glossary in its prompt, so a
/// correction is read back from what the two texts show. A glossary term the
/// summary uses and the transcript never spells that way, but that a piece of
/// the transcript reads as a mishearing of, was corrected.
///
/// A term absent from both texts is an invention, not a correction, and a term
/// whose only difference is capitalization is not one either.
public struct GlossaryJargonCorrector: JargonCorrectionStrategy {
    public init() {}

    public func correct(summary: SummaryDraft, glossary: Glossary) async throws -> [JargonCorrection] {
        Self.corrections(summaryText: summary.summaryText, transcriptText: summary.transcriptText, glossary: glossary)
    }

    private struct Found {
        let range: ByteRange
        let corrected: String
        let original: String
    }

    /// Synchronous so the wedge measurement can call it without a task.
    ///
    /// Person terms match on their whole text only, not on a name part: the
    /// summary saying "Ben Smith" where the transcript says "Ben" is the
    /// summarizer completing a name, not a mistranscription being fixed, and
    /// counting it would inflate the rate the wedge criterion is judged on.
    static func corrections(summaryText: String, transcriptText: String, glossary: Glossary) -> [JargonCorrection] {
        var transcriptIndex: FuzzyTermMatcher.TextIndex?
        var found: [Found] = []
        var seen = Set<String>()

        let terms = glossary.people + glossary.projects + glossary.concepts + glossary.uncategorized
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            guard let summaryRange = firstWholeTermRange(of: trimmed, in: summaryText) else { continue }
            guard firstWholeTermRange(of: trimmed, in: transcriptText) == nil else { continue }

            let index = transcriptIndex ?? FuzzyTermMatcher.TextIndex(transcriptText)
            transcriptIndex = index
            guard let match = index.bestMatch(of: FuzzyTermMatcher.Term(trimmed)) else { continue }
            guard match.text.caseInsensitiveCompare(trimmed) != .orderedSame else { continue }
            guard !isInflection(match.text, of: trimmed) else { continue }

            let start = summaryText.utf8.distance(from: summaryText.startIndex, to: summaryRange.lowerBound)
            let end = summaryText.utf8.distance(from: summaryText.startIndex, to: summaryRange.upperBound)
            found.append(Found(range: ByteRange(start: start, end: end), corrected: String(summaryText[summaryRange]), original: match.text))
        }

        return found
            .sorted { ($0.range.start, $0.range.end) < ($1.range.start, $1.range.end) }
            .map { item in
                JargonCorrection(
                    suggestionId: "jargon-\(item.range.start)-\(item.range.end)",
                    reasoning: "The vault glossary has \"\(item.corrected)\"; the transcript's \"\(item.original)\" reads as a mishearing of it.",
                    charRange: item.range,
                    originalSpan: item.original,
                    correctedSpan: item.corrected,
                )
            }
    }

    private static let inflectionSuffixes = ["s", "es", "d", "ed", "ing"]

    /// A plural or tense form is the speaker's grammar, not a mishearing: the
    /// squashed forms differ by nothing but a trailing suffix, in either
    /// direction.
    private static func isInflection(_ candidate: String, of term: String) -> Bool {
        let (candidateForm, termForm) = (FuzzyTermMatcher.squash(candidate), FuzzyTermMatcher.squash(term))
        return inflectionSuffixes.contains { suffix in
            candidateForm == termForm + suffix || termForm == candidateForm + suffix
        }
    }

    /// The first occurrence of `term` that is not the middle of a longer word,
    /// compared case-insensitively.
    private static func firstWholeTermRange(of term: String, in text: String) -> Range<String.Index>? {
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: term, options: .caseInsensitive, range: searchStart ..< text.endIndex) {
            let precededByWord = range.lowerBound > text.startIndex && isWordCharacter(text[text.index(before: range.lowerBound)])
            let followedByWord = range.upperBound < text.endIndex && isWordCharacter(text[range.upperBound])
            if !precededByWord, !followedByWord {
                return range
            }
            searchStart = text.index(after: range.lowerBound)
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }
}
