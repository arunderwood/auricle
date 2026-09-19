import Foundation

/// The index and tokenizing machinery behind `FuzzyTermMatcher`'s public
/// surface, kept apart so the public file reads as the contract.
extension FuzzyTermMatcher {
    /// One word of a person term's name, matched on its own against a single
    /// word of the text.
    struct NamePart {
        let squashed: [UInt32]
        let signature: Signature
        let allowedEdits: Int
    }

    /// A 128-bit bloom filter of a squashed form's adjacent character pairs.
    /// One edit changes at most two pairs of each string, so two forms within
    /// `k` edits have signatures differing in at most `4k` bits (a bloom
    /// collision can only lower the count), and a candidate that differs in
    /// more is rejected without computing its edit distance.
    struct Signature: Sendable {
        let low: UInt64
        let high: UInt64

        init(of scalars: [UInt32]) {
            var low: UInt64 = 0
            var high: UInt64 = 0
            func add(_ first: UInt32, _ second: UInt32) {
                let mixed = (first &* 0x9E37_79B1) &+ (second &* 0x85EB_CA6B)
                let bit = (mixed ^ (mixed >> 13)) & 127
                if bit < 64 {
                    low |= 1 << UInt64(bit)
                } else {
                    high |= 1 << UInt64(bit - 64)
                }
            }
            if scalars.count == 1 {
                add(scalars[0], 0)
            }
            for index in scalars.indices.dropFirst() {
                add(scalars[index - 1], scalars[index])
            }
            self.low = low
            self.high = high
        }

        func differingBits(from other: Signature) -> Int {
            (low ^ other.low).nonzeroBitCount + (high ^ other.high).nonzeroBitCount
        }
    }

    // MARK: - Windows

    struct Window: Sendable {
        let squashed: [UInt32]
        let signature: Signature
        let lowerBound: String.Index
        let upperBound: String.Index
        /// Reading order, so a tie goes to the earliest window.
        let order: Int
    }

    struct WindowSet: Sendable {
        /// Parallel arrays rather than one array of windows: the hot loop reads
        /// only signatures and copies no squashed form until one survives.
        private var windows: [Window] = []
        private var signatures: [Signature] = []
        private var exact: [[UInt32]: Int] = [:]
        private var byLength: [Int: [Int]] = [:]

        /// Keeps the first window for a squashed form: a later window with
        /// the same form can never win a tie.
        mutating func insert(_ window: Window) {
            guard exact[window.squashed] == nil else { return }
            let index = windows.count
            windows.append(window)
            signatures.append(window.signature)
            exact[window.squashed] = index
            byLength[window.squashed.count, default: []].append(index)
        }

        func closest(to squashed: [UInt32], signature: Signature, allowedEdits: Int) -> (distance: Int, window: Window)? {
            if let hit = exact[squashed] {
                return (0, windows[hit])
            }
            guard allowedEdits > 0 else { return nil }
            var best: (distance: Int, window: Window)?
            for length in max(1, squashed.count - allowedEdits) ... (squashed.count + allowedEdits) {
                guard let indices = byLength[length] else { continue }
                for index in indices where signatures[index].differingBits(from: signature) <= 4 * allowedEdits {
                    let bound = best?.distance ?? allowedEdits
                    guard let distance = FuzzyTermMatcher.distance(squashed, windows[index].squashed, limit: bound) else { continue }
                    if let current = best, (distance, windows[index].order) >= (current.distance, current.window.order) {
                        continue
                    }
                    best = (distance, windows[index])
                }
            }
            return best
        }
    }

    // MARK: - Tokenizing

    struct Word {
        let squashed: [UInt32]
        let lowerBound: String.Index
        let upperBound: String.Index
        let line: Int
    }

    /// Whitespace-separated words with their surrounding punctuation trimmed
    /// off the reported range, so a match reads as the words themselves.
    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var line = 0
        var firstOnLine = true
        var tokenStart: String.Index?

        func emit(_ start: String.Index, _ end: String.Index) {
            let isLabelPosition = firstOnLine
            firstOnLine = false
            let token = text[start ..< end]
            if isLabelPosition, token.hasPrefix("Speaker_"), token.hasSuffix(":") {
                return
            }
            var lower = start
            var upper = end
            while lower < upper, !isWordCharacter(text[lower]) {
                lower = text.index(after: lower)
            }
            while upper > lower, !isWordCharacter(text[text.index(before: upper)]) {
                upper = text.index(before: upper)
            }
            guard lower < upper else { return }
            let squashed = squashedScalars(text[lower ..< upper])
            guard !squashed.isEmpty else { return }
            words.append(Word(squashed: squashed, lowerBound: lower, upperBound: upper, line: line))
        }

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace {
                if let start = tokenStart {
                    emit(start, index)
                    tokenStart = nil
                }
                if character.isNewline {
                    line += 1
                    firstOnLine = true
                }
            } else if tokenStart == nil {
                tokenStart = index
            }
            index = text.index(after: index)
        }
        if let start = tokenStart {
            emit(start, text.endIndex)
        }
        return words
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - Squashing and distance

    static func squashedScalars(_ text: Substring) -> [UInt32] {
        var scalars: [UInt32] = []
        scalars.reserveCapacity(text.utf8.count)
        var isASCII = true
        for byte in text.utf8 {
            switch byte {
            case 0x30 ... 0x39, 0x61 ... 0x7A:
                scalars.append(UInt32(byte))
            case 0x41 ... 0x5A:
                scalars.append(UInt32(byte) + 0x20)
            case 0x80...:
                isASCII = false
            default:
                break
            }
            if !isASCII {
                break
            }
        }
        if isASCII {
            return scalars
        }

        scalars.removeAll(keepingCapacity: true)
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            scalars.append(scalar.value)
        }
        return scalars
    }

    /// Levenshtein distance when it is at most `limit`, else `nil`, giving up
    /// as soon as no cell of a row can come back under the limit.
    static func distance(_ first: [UInt32], _ second: [UInt32], limit: Int) -> Int? {
        let firstCount = first.count
        let secondCount = second.count
        guard abs(firstCount - secondCount) <= limit else { return nil }
        guard firstCount > 0, secondCount > 0 else {
            let total = firstCount + secondCount
            return total <= limit ? total : nil
        }

        return first.withUnsafeBufferPointer { firstScalars in
            second.withUnsafeBufferPointer { secondScalars in
                withUnsafeTemporaryAllocation(of: Int.self, capacity: 2 * (secondCount + 1)) { rows in
                    var previous = rows.baseAddress!
                    var current = previous + (secondCount + 1)
                    for column in 0 ... secondCount {
                        previous[column] = column
                    }
                    for row in 1 ... firstCount {
                        current[0] = row
                        var rowMinimum = row
                        for column in 1 ... secondCount {
                            let substitution = previous[column - 1] + (firstScalars[row - 1] == secondScalars[column - 1] ? 0 : 1)
                            let value = min(previous[column] + 1, current[column - 1] + 1, substitution)
                            current[column] = value
                            rowMinimum = min(rowMinimum, value)
                        }
                        guard rowMinimum <= limit else { return nil }
                        swap(&previous, &current)
                    }
                    let result = previous[secondCount]
                    return result <= limit ? result : nil
                }
            }
        }
    }
}
