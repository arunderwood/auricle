import Testing
@testable import VaultGlossary

private func match(_ term: String, in text: String, isPerson: Bool = false) -> FuzzyTermMatcher.Match? {
    FuzzyTermMatcher.TextIndex(text).bestMatch(of: FuzzyTermMatcher.Term(term, isPerson: isPerson))
}

@Test func squashLowercasesFoldsDiacriticsAndDropsEverythingButLettersAndDigits() {
    #expect(FuzzyTermMatcher.squash("Mesh Core") == "meshcore")
    #expect(FuzzyTermMatcher.squash("Café") == "cafe")
    #expect(FuzzyTermMatcher.squash("AI-2 Lab!") == "ai2lab")
    #expect(FuzzyTermMatcher.squash("🚀 --- ") == "")
}

@Test func theEditAllowanceGrowsWithTheTermLength() {
    #expect(FuzzyTermMatcher.allowedEdits(forSquashedLength: 3) == 0)
    #expect(FuzzyTermMatcher.allowedEdits(forSquashedLength: 4) == 1)
    #expect(FuzzyTermMatcher.allowedEdits(forSquashedLength: 7) == 1)
    #expect(FuzzyTermMatcher.allowedEdits(forSquashedLength: 8) == 2)
}

@Test func aTermSpacedDifferentlyInTheTranscriptStillMatches() throws {
    let found = try #require(match("meshcore", in: "we run mesh core on the roof"))

    #expect(found.text == "mesh core")
    #expect(found.distance == 0)
}

@Test func aMatchReadsAsTheWordsThemselvesWithoutSurroundingPunctuation() throws {
    #expect(try #require(match("meshcore", in: "we like (mesh core), mostly")).text == "mesh core")
}

@Test func aTermThatIsSpelledTheSameMatchesExactly() throws {
    let found = try #require(match("Packet Radio", in: "Talked about PACKET radio today."))

    #expect(found.distance == 0)
    #expect(found.text == "PACKET radio")
}

@Test func fourToSevenCharacterTermsTolerateOneEditAndNoMore() throws {
    #expect(try #require(match("radio", in: "the radeo was loud")).distance == 1)
    #expect(match("radio", in: "the rodeo was loud") == nil)
}

@Test func eightOrMoreCharacterTermsTolerateTwoEditsAndNoMore() throws {
    #expect(try #require(match("meshcore", in: "using meshkora now")).distance == 2)
    #expect(match("meshcore", in: "using mishkorb now") == nil)
}

@Test func termsUnderFourCharactersMatchOnlyExactly() {
    #expect(match("Ben", in: "ask Ben about it") != nil)
    #expect(match("Ben", in: "ask Bin about it") == nil)
    #expect(match("Ben", in: "ask Bent about it") == nil)
}

@Test func anUnrelatedTermDoesNotMatch() {
    #expect(match("zebra", in: "we talked about the roadmap and the budget") == nil)
}

@Test func aTermWithNoLettersOrDigitsMatchesNothing() {
    #expect(match("🚀", in: "ship it 🚀 now") == nil)
}

@Test func aTermSpreadOverFourWordsMatchesAndOneSpreadOverFiveDoesNot() throws {
    #expect(try #require(match("quarterly planning offsite", in: "the quarterly planning off site is on")).distance <= 1)
    #expect(match("abcd", in: "a b c d") != nil)
    #expect(match("abcdef", in: "a b c d e f") == nil)
}

@Test func windowsDoNotCrossALineBreak() {
    #expect(match("meshcore", in: "mesh\ncore") == nil)
    #expect(match("meshcore", in: "mesh core") != nil)
}

@Test func aSpeakerLabelIsNotAWordInTheText() {
    #expect(match("speaker", in: "Speaker_1: hello there\nSpeaker_2: hi") == nil)
    #expect(match("speaker", in: "Speaker_1: the speaker said hi") != nil)
}

@Test func aPersonTermMatchesOnASingleNamePartOfThreeOrMoreCharacters() throws {
    let found = try #require(match("Priya Patel", in: "Priya said hi", isPerson: true))

    #expect(found.text == "Priya")
    #expect(match("Priya Patel", in: "Priya said hi") == nil)
}

@Test func aNamePartUnderThreeCharactersDoesNotMatchOnItsOwn() {
    #expect(match("Jo Smith", in: "Jo said hi", isPerson: true) == nil)
    #expect(match("Jo Smith", in: "Smith said hi", isPerson: true) != nil)
}

@Test func aNamePartToleratesTheEditsItsOwnLengthAllows() throws {
    #expect(try #require(match("Priya Patel", in: "Pria said hi", isPerson: true)).distance == 1)
    #expect(match("Ben Smith", in: "Bin said hi", isPerson: true) == nil)
}

@Test func theClosestWindowWinsAndTheEarliestBreaksATie() throws {
    let text = "the radeo and the radio and the rodio"
    #expect(try #require(match("radio", in: text)).text == "radio")
    #expect(try #require(match("radio", in: "a radeo then a radko")).text == "radeo")
}

// MARK: - Prefilters never change the answer

/// Deterministic, so a failure reproduces.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private func levenshtein(_ first: [Character], _ second: [Character]) -> Int {
    var previous = Array(0 ... second.count)
    for (row, firstCharacter) in first.enumerated() {
        var current = [row + 1]
        for (column, secondCharacter) in second.enumerated() {
            current.append(min(previous[column + 1] + 1, current[column] + 1, previous[column] + (firstCharacter == secondCharacter ? 0 : 1)))
        }
        previous = current
    }
    return previous[second.count]
}

/// The smallest edit distance between the squashed term and any window of one
/// to four words, or `nil` when none is within the term's allowance.
private func bruteForceDistance(term: String, words: [String]) -> Int? {
    let squashedTerm = Array(FuzzyTermMatcher.squash(term))
    let allowed = FuzzyTermMatcher.allowedEdits(forSquashedLength: squashedTerm.count)
    var best: Int?
    for start in words.indices {
        for count in 1 ... FuzzyTermMatcher.maxWindowWords where start + count <= words.count {
            let window = Array(FuzzyTermMatcher.squash(words[start ..< start + count].joined()))
            let distance = levenshtein(squashedTerm, window)
            if distance <= allowed, distance < (best ?? .max) {
                best = distance
            }
        }
    }
    return best
}

@Test func theIndexFindsExactlyWhatAnExhaustiveEditDistanceSearchFinds() {
    var generator = SeededGenerator(state: 42)
    let alphabet = Array("abcd")
    func randomWord(_ lengths: ClosedRange<Int>) -> String {
        String((0 ..< Int.random(in: lengths, using: &generator)).map { _ in alphabet.randomElement(using: &generator)! })
    }

    var matched = 0
    for _ in 0 ..< 20 {
        let words = (0 ..< 30).map { _ in randomWord(1 ... 4) }
        let index = FuzzyTermMatcher.TextIndex(words.joined(separator: " "))
        for _ in 0 ..< 50 {
            let term = randomWord(4 ... 9)
            let expected = bruteForceDistance(term: term, words: words)
            let actual = index.bestMatch(of: FuzzyTermMatcher.Term(term))?.distance
            #expect(actual == expected, "term \(term) in \(words.joined(separator: " "))")
            if expected != nil {
                matched += 1
            }
        }
    }
    #expect(matched > 100)
}
