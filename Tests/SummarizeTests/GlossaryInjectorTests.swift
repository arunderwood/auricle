import Core
import Foundation
@testable import Summarize
import Testing

private func transcript(_ text: String) -> CanonicalTranscript {
    CanonicalTranscript(text: text, utterances: [])
}

@Test func aTermTheTranscriptSpellsWronglySurvivesScoping() {
    let glossary = Glossary(concepts: ["meshcore"])

    let scoped = GlossaryInjector.scope(glossary, transcript: transcript("Speaker_1: we run mesh core on the roof"), attendees: [])

    #expect(scoped.concepts == ["meshcore"])
}

@Test func aTermTheTranscriptNeverMentionsIsDropped() {
    let glossary = Glossary(concepts: ["zebra"], uncategorized: ["meshcore"])

    let scoped = GlossaryInjector.scope(glossary, transcript: transcript("Speaker_1: we run mesh core on the roof"), attendees: [])

    #expect(scoped.concepts.isEmpty)
    #expect(scoped.uncategorized == ["meshcore"])
}

@Test func anAttendeeAloneKeepsThePersonTermWhenTheTranscriptIsSilent() {
    let glossary = Glossary(people: ["Priya Patel"])
    let silent = transcript("Speaker_1: nothing relevant is said here")

    #expect(GlossaryInjector.scope(glossary, transcript: silent, attendees: ["Priya"]).people == ["Priya Patel"])
    #expect(GlossaryInjector.scope(glossary, transcript: silent, attendees: []).people.isEmpty)
}

@Test func aFullAttendeeNameKeepsThePersonTermToo() {
    let glossary = Glossary(people: ["Priya Patel"])

    let scoped = GlossaryInjector.scope(glossary, transcript: transcript("nothing"), attendees: ["Priya Patel"])

    #expect(scoped.people == ["Priya Patel"])
}

@Test func aPersonTermIsKeptWhenOneOfItsNamePartsIsSpoken() {
    let glossary = Glossary(people: ["Ben Smith", "Zed Zulu"])

    let scoped = GlossaryInjector.scope(glossary, transcript: transcript("Speaker_1: ask Ben about it"), attendees: [])

    #expect(scoped.people == ["Ben Smith"])
}

@Test func anAttendeeNameDoesNotKeepATermThatIsNotAPerson() {
    let glossary = Glossary(concepts: ["Priya"])

    let scoped = GlossaryInjector.scope(glossary, transcript: transcript("nothing"), attendees: ["Priya"])

    #expect(scoped.concepts.isEmpty)
}

@Test func aHugeGlossaryIsCappedAtFortyTermsAndRendersNearTwoHundredTokens() throws {
    let terms = (0 ..< 2000).map { "Term \(String(format: "%04d", $0))" }
    let glossary = Glossary(concepts: terms)
    let spoken = transcript(terms.map { "Speaker_1: we covered \($0) today." }.joined(separator: "\n"))

    let scoped = GlossaryInjector.scope(glossary, transcript: spoken, attendees: [])

    #expect(scoped.concepts.count == GlossaryInjector.maxTerms)
    #expect(scoped.concepts == Array(terms.prefix(GlossaryInjector.maxTerms)))
    let scopedTokens = try renderedTokenEstimate(scoped, transcript: spoken)
    let unscopedTokens = try renderedTokenEstimate(glossary, transcript: spoken)
    #expect(scopedTokens <= 200)
    #expect(unscopedTokens >= 5000)
}

@Test func whenTooManyTermsQualifyTheClosestMatchesWinBeforeAlphabeticalOrder() {
    let exact = (10 ..< 50).map { "term\($0)" }
    let mangled = ["aardvark", "abalone", "acorn", "adder", "agouti"]
    let spoken = transcript(
        (exact + ["aardvarc", "abalona", "acorm", "addar", "agouta"]).joined(separator: " "),
    )
    let glossary = Glossary(concepts: mangled + exact)

    let scoped = GlossaryInjector.scope(glossary, transcript: spoken, attendees: [])

    #expect(scoped.concepts == exact)
}

@Test func scopingIsDeterministicAndKeepsTheInputOrderWithinEachCategory() {
    let glossary = Glossary(
        people: ["Ada Lovelace", "Ben Smith"],
        projects: ["chicken-palace"],
        concepts: ["meshcore", "packet radio"],
        uncategorized: ["Friday"],
    )
    let spoken = transcript("Ada, Ben, chicken palace, mesh core, packet radio, Friday")

    let first = GlossaryInjector.scope(glossary, transcript: spoken, attendees: ["Ben"])
    let second = GlossaryInjector.scope(glossary, transcript: spoken, attendees: ["Ben"])

    #expect(first == second)
    #expect(first == glossary)
}

@Test func anEmptyGlossaryScopesToAnEmptyGlossary() {
    #expect(GlossaryInjector.scope(Glossary(), transcript: transcript("anything"), attendees: ["Ben"]) == Glossary())
}

@Test func attendeeNamesStripBracketsDropBlanksAndDeduplicate() {
    let names = AttributionSpeakers.attendeeNames(from: [
        "Speaker_2": "[[Ben]]",
        "Speaker_1": " [[Ada Lovelace]] ",
        "Speaker_3": "ben",
        "Speaker_4": "[[ ]]",
    ])

    #expect(names == ["Ada Lovelace", "Ben"])
    #expect(AttributionSpeakers.attendeeNames(from: nil).isEmpty)
}

/// Whole-prompt cost is not what the bound is about: only the glossary block,
/// at about four characters a token.
private func renderedTokenEstimate(_ glossary: Glossary, transcript: CanonicalTranscript) throws -> Int {
    let prompt = try SummarizationPromptBuilder.build(transcript: transcript, glossary: glossary, attendees: [], mode: .substring)
    return prompt.glossary.text.count / 4
}
