import Core
import VaultGlossary

/// Narrows the vault-wide glossary to the terms one meeting can use (FR56), so
/// the prompt's glossary block stays near 200 tokens however large the vault
/// is. The whole glossary is thousands of terms and would cost more than the
/// transcript's own context is worth.
///
/// Matching is fuzzy on purpose. A term speech recognition mangled
/// (`meshcore` heard as "mesh core") has no exact mention, and dropping it
/// would drop precisely the terms jargon correction exists to fix.
public enum GlossaryInjector {
    /// Around 200 tokens once rendered as `[[wikilink]]` lines.
    public static let maxTerms = 40

    /// Keeps a person term that fuzzy-matches an attendee name or a transcript
    /// word, and any other term that fuzzy-matches the transcript. When more
    /// than `maxTerms` qualify, the closest matches win, then alphabetical
    /// order, so the same inputs always give the same glossary.
    ///
    /// Takes attendee names and the transcript rather than a meeting record:
    /// the record the persist stage renders from does not exist until after
    /// summarization.
    public static func scope(_ glossary: Glossary, transcript: CanonicalTranscript, attendees: [String]) -> Glossary {
        let transcriptIndex = FuzzyTermMatcher.TextIndex(transcript.text)
        let attendeeIndex = attendees.isEmpty ? nil : FuzzyTermMatcher.TextIndex(attendees.joined(separator: "\n"))

        var candidates: [Candidate] = []
        for category in Category.allCases {
            for (position, text) in terms(of: category, in: glossary).enumerated() {
                let term = FuzzyTermMatcher.Term(text, isPerson: category == .people)
                var distance = transcriptIndex.bestMatch(of: term)?.distance
                if category == .people, let attendeeDistance = attendeeIndex?.bestMatch(of: term)?.distance {
                    distance = min(distance ?? attendeeDistance, attendeeDistance)
                }
                if let distance {
                    candidates.append(Candidate(category: category, position: position, term: text, distance: distance))
                }
            }
        }

        candidates.sort { $0.precedes($1) }
        let kept = Set(candidates.prefix(maxTerms).map { KeptTerm(category: $0.category, position: $0.position) })

        func filtered(_ category: Category) -> [String] {
            terms(of: category, in: glossary).enumerated().compactMap { position, term in
                kept.contains(KeptTerm(category: category, position: position)) ? term : nil
            }
        }
        return Glossary(
            people: filtered(.people),
            projects: filtered(.projects),
            concepts: filtered(.concepts),
            uncategorized: filtered(.uncategorized),
        )
    }

    private enum Category: Int, CaseIterable {
        case people
        case projects
        case concepts
        case uncategorized
    }

    private static func terms(of category: Category, in glossary: Glossary) -> [String] {
        switch category {
        case .people: glossary.people
        case .projects: glossary.projects
        case .concepts: glossary.concepts
        case .uncategorized: glossary.uncategorized
        }
    }

    private struct KeptTerm: Hashable {
        let category: Category
        let position: Int
    }

    private struct Candidate {
        let category: Category
        let position: Int
        let term: String
        let distance: Int

        /// Closest match first, then alphabetical, with category and position
        /// only to keep two equal spellings in a fixed order.
        func precedes(_ other: Candidate) -> Bool {
            if distance != other.distance {
                return distance < other.distance
            }
            let (mine, theirs) = (term.lowercased(), other.term.lowercased())
            if mine != theirs {
                return mine < theirs
            }
            if term != other.term {
                return term < other.term
            }
            if category != other.category {
                return category.rawValue < other.category.rawValue
            }
            return position < other.position
        }
    }
}
