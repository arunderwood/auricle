import Foundation

/// Decides whether a glossary term is mentioned in a text even when speech
/// recognition mangled it (`meshcore` heard as "mesh core"). Glossary scoping
/// and the jargon corrector share this squash-and-edit-distance matching. Only
/// scoping also matches a person on a single name part; the corrector matches
/// a person term on its whole text.
///
/// Matching happens on squashed forms: lowercase, diacritics folded, everything
/// that is not a letter or digit dropped. A window of one to four consecutive
/// words is squashed and compared with the squashed term, and the term and the
/// window are a match when they are within a bounded edit distance. There is no
/// phonetic matching: a mishearing that sounds alike but is spelled differently
/// by more than the allowance is not found.
public enum FuzzyTermMatcher {
    /// The longest run of consecutive words compared with a term.
    public static let maxWindowWords = 4
    /// The shortest squashed name part a person term may match on alone.
    public static let minNamePartLength = 3

    /// A window longer than this can never be within the edit allowance of any
    /// realistic term, so it is not indexed.
    private static let maxWindowLength = 64

    /// 0 below 4 characters, 1 for 4 to 7, 2 for 8 or more. A short term
    /// tolerates no edit because one edit turns it into an unrelated word.
    public static func allowedEdits(forSquashedLength length: Int) -> Int {
        switch length {
        case ..<4: 0
        case 4 ..< 8: 1
        default: 2
        }
    }

    /// Lowercase, diacritics folded, non-alphanumerics dropped.
    public static func squash(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for value in squashedScalars(text[...]) {
            if let scalar = Unicode.Scalar(value) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// The text of the best-matching window, and how many edits away it is.
    public struct Match: Sendable, Equatable {
        public let text: String
        public let distance: Int

        public init(text: String, distance: Int) {
            self.text = text
            self.distance = distance
        }
    }

    /// A glossary term prepared for matching. A person term also carries its
    /// name parts, so "Priya Patel" is found by the single word "Priya".
    public struct Term: Sendable {
        public let text: String
        let squashed: [UInt32]
        let signature: Signature
        let allowedEdits: Int
        let nameParts: [NamePart]

        public init(_ text: String, isPerson: Bool = false) {
            self.text = text
            let squashed = FuzzyTermMatcher.squashedScalars(text[...])
            self.squashed = squashed
            signature = FuzzyTermMatcher.Signature(of: squashed)
            allowedEdits = FuzzyTermMatcher.allowedEdits(forSquashedLength: squashed.count)

            guard isPerson else {
                nameParts = []
                return
            }
            let pieces = text.split(whereSeparator: { $0.isWhitespace })
            guard pieces.count > 1 else {
                nameParts = []
                return
            }
            nameParts = pieces.compactMap { piece in
                let partSquashed = FuzzyTermMatcher.squashedScalars(piece)
                guard partSquashed.count >= FuzzyTermMatcher.minNamePartLength else { return nil }
                return NamePart(
                    squashed: partSquashed,
                    signature: FuzzyTermMatcher.Signature(of: partSquashed),
                    allowedEdits: FuzzyTermMatcher.allowedEdits(forSquashedLength: partSquashed.count),
                )
            }
        }
    }

    /// A text tokenized once and searchable for many terms. Windows never
    /// cross a line break, and a leading `Speaker_N:` label is not a word, so
    /// neither a turn boundary nor a label can build a match.
    public struct TextIndex: Sendable {
        private let text: String
        private let allWindows: WindowSet
        private let singleWordWindows: WindowSet

        public init(_ text: String) {
            self.text = text
            var all = WindowSet()
            var singles = WindowSet()
            let words = FuzzyTermMatcher.words(in: text)
            var order = 0
            for start in words.indices {
                var squashed: [UInt32] = []
                let limit = min(words.count, start + FuzzyTermMatcher.maxWindowWords)
                for end in start ..< limit {
                    guard words[end].line == words[start].line else { break }
                    squashed += words[end].squashed
                    guard squashed.count <= FuzzyTermMatcher.maxWindowLength else { break }
                    let window = Window(
                        squashed: squashed,
                        signature: Signature(of: squashed),
                        lowerBound: words[start].lowerBound,
                        upperBound: words[end].upperBound,
                        order: order,
                    )
                    order += 1
                    all.insert(window)
                    if end == start {
                        singles.insert(window)
                    }
                }
            }
            allWindows = all
            singleWordWindows = singles
        }

        /// The closest window to `term` within its edit allowance, the
        /// earliest one on a tie; `nil` when nothing is close enough. A term
        /// with no letters or digits matches nothing.
        public func bestMatch(of term: Term) -> Match? {
            guard !term.squashed.isEmpty else { return nil }
            var best = allWindows.closest(to: term.squashed, signature: term.signature, allowedEdits: term.allowedEdits)
            for part in term.nameParts {
                guard let candidate = singleWordWindows.closest(to: part.squashed, signature: part.signature, allowedEdits: part.allowedEdits) else {
                    continue
                }
                if let current = best, (current.distance, current.window.order) <= (candidate.distance, candidate.window.order) {
                    continue
                }
                best = candidate
            }
            guard let best else { return nil }
            return Match(text: String(text[best.window.lowerBound ..< best.window.upperBound]), distance: best.distance)
        }
    }
}
