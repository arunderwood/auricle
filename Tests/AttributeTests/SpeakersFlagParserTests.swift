@testable import Attribute
import Core
import Testing

private let labels = ["Speaker_1", "Speaker_2", "Speaker_3"]

@Test func aMappingNamesTheListedSpeakersAndLeavesTheRestAsPlaceholders() throws {
    let map = try SpeakersFlagParser.parse("1=Ben,2=Jordan Whitfield", labels: labels)
    #expect(map == ["Speaker_1": "[[Ben]]", "Speaker_2": "[[Jordan Whitfield]]", "Speaker_3": "Speaker_3"])
}

@Test func aGlossaryPersonUsesTheGlossarySpellingCaseInsensitively() throws {
    let glossary = Glossary(people: ["Jordan Whitfield"])
    let map = try SpeakersFlagParser.parse("2=jordan whitfield", labels: labels, glossary: glossary)
    #expect(map["Speaker_2"] == "[[Jordan Whitfield]]")
}

@Test func whitespaceAroundEntriesAndBracketsInNamesAreTolerated() throws {
    let map = try SpeakersFlagParser.parse(" 1 = [[Ben]] , 3=Sara ", labels: labels)
    #expect(map["Speaker_1"] == "[[Ben]]")
    #expect(map["Speaker_3"] == "[[Sara]]")
}

@Test(arguments: [
    ("", SpeakersFlagError.noEntries),
    ("1=Ben,1=Sara", .duplicateKey("1")),
    ("1=Ben,2=ben", .duplicateName("ben")),
    ("9=Ben", .unknownSpeaker("9=Ben")),
    ("1=", .emptyName("1=")),
    ("1=[[ ]]", .emptyName("1=[[ ]]")),
    ("Ben", .malformedEntry("Ben")),
    ("x=Ben", .malformedEntry("x=Ben")),
    ("1=Ben,,2=Sara", .malformedEntry("")),
    ("=Ben", .malformedEntry("=Ben")),
    ("1=Speaker_2", .malformedEntry("1=Speaker_2")),
    ("1=[[Speaker_2]]", .malformedEntry("1=[[Speaker_2]]")),
])
func aBadMappingIsRefusedWithTheOffendingEntry(raw: String, expected: SpeakersFlagError) {
    #expect(throws: expected) { try SpeakersFlagParser.parse(raw, labels: labels) }
}

@Test func twoSpellingsOfAGlossaryNameAreDuplicates() {
    let glossary = Glossary(people: ["Ben"])
    #expect(throws: SpeakersFlagError.duplicateName("Ben")) {
        try SpeakersFlagParser.parse("1=Ben,2=BEN", labels: labels, glossary: glossary)
    }
}
