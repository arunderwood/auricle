import Core
import Testing

@Test("Bare, wrapped and padded text normalizes to one wikilink", arguments: [
    ("Jordan", "[[Jordan]]"),
    ("[[Jordan]]", "[[Jordan]]"),
    ("  [[Jordan]]  ", "[[Jordan]]"),
    ("[[ Jordan Lee ]]", "[[Jordan Lee]]"),
    ("  Jordan Lee\n", "[[Jordan Lee]]"),
])
func selfWikilinkNormalizesAcceptedText(text: String, expected: String) throws {
    #expect(try SelfWikilink.normalized(text) == expected)
}

@Test("Text with no target is empty", arguments: ["", "  ", "[[ ]]", "[[]]"])
func selfWikilinkRejectsEmptyText(text: String) {
    #expect(throws: SelfWikilinkError.empty) {
        try SelfWikilink.normalized(text)
    }
}

@Test("Link syntax, newlines and stray brackets are malformed", arguments: [
    "[[|me]]", "[[Jordan|]]", "[[Jordan Lee|Jordan]]", "[[Jo\n]]", "[[Name#Heading]]", "Jo^n", "a\\b",
    "[[Jo]]n]]", "Jo[n", "[[Jordan", "Jordan]]", "Jo\u{0007}n",
])
func selfWikilinkRejectsMalformedText(text: String) {
    #expect(throws: SelfWikilinkError.malformed) {
        try SelfWikilink.normalized(text)
    }
}

@Test func fromNameDropsLinkSyntaxAndCollapsesWhitespace() {
    #expect(SelfWikilink.fromName("Jordan Lee") == "Jordan Lee")
    #expect(SelfWikilink.fromName(#"Jo[r]d|a#n^ \Lee"#) == "Jordan Lee")
    #expect(SelfWikilink.fromName("  Jordan\n\t  Lee  ") == "Jordan Lee")
    #expect(SelfWikilink.fromName("Jo\u{0007}rdan") == "Jordan")
}

@Test("A name with nothing usable is nil", arguments: ["", "   ", "\n\t", "[]|#^\\"])
func fromNameIsNilWhenNothingRemains(name: String) {
    #expect(SelfWikilink.fromName(name) == nil)
}

@Test func whatFromNameProducesAlwaysNormalizes() throws {
    let name = try #require(SelfWikilink.fromName("  Jo[r]dan\n Lee|#^ "))
    #expect(try SelfWikilink.normalized(name) == "[[\(name)]]")
}
