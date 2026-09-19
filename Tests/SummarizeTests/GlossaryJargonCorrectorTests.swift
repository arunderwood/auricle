import AIReviewerInterface
import Core
import Foundation
@testable import Summarize
import Testing

private func corrections(summary: String, transcript: String, glossary: Glossary) -> [JargonCorrection] {
    GlossaryJargonCorrector.corrections(summaryText: summary, transcriptText: transcript, glossary: glossary)
}

private func slice(_ text: String, _ range: ByteRange) -> String {
    String(bytes: Array(text.utf8)[range.start ..< range.end], encoding: .utf8) ?? ""
}

@Test func aMangledTermTheSummaryHasCorrectedIsFound() throws {
    let summary = "Café notes: rolled out [[meshcore]] on the roof."
    let transcript = "Speaker_1: we rolled out mesh core on the roof"

    let found = corrections(summary: summary, transcript: transcript, glossary: Glossary(concepts: ["meshcore"]))

    let correction = try #require(found.first)
    #expect(found.count == 1)
    #expect(correction.originalSpan == "mesh core")
    #expect(correction.correctedSpan == "meshcore")
    #expect(slice(summary, correction.charRange) == "meshcore")
    #expect(correction.reasoning.contains("mesh core"))
    #expect(correction.reasoning.contains("meshcore"))
}

@Test func theCharRangeCountsUTF8BytesNotCharacters() throws {
    let summary = "Café 🚀 [[meshcore]]"

    let correction = try #require(corrections(summary: summary, transcript: "a mesh core b", glossary: Glossary(concepts: ["meshcore"])).first)

    #expect(correction.charRange.start == "Café 🚀 [[".utf8.count)
    #expect(correction.charRange.end - correction.charRange.start == "meshcore".utf8.count)
}

@Test func aTermSpelledExactlyInTheTranscriptIsNotACorrection() {
    let found = corrections(summary: "Uses [[meshcore]].", transcript: "we use meshcore daily", glossary: Glossary(concepts: ["meshcore"]))

    #expect(found.isEmpty)
}

@Test func aCaseOnlyDifferenceIsNotACorrection() {
    let found = corrections(summary: "Uses [[MeshCore]].", transcript: "we use MESHCORE daily", glossary: Glossary(concepts: ["meshcore"]))

    #expect(found.isEmpty)
}

@Test func aTermInNeitherTextIsAnInventionNotACorrection() {
    let found = corrections(summary: "Talked about the budget.", transcript: "we talked about the budget", glossary: Glossary(concepts: ["meshcore"]))

    #expect(found.isEmpty)
}

@Test func aTermOnlyInTheSummaryWithNothingCloseInTheTranscriptIsNotACorrection() {
    let found = corrections(summary: "Uses [[meshcore]].", transcript: "we talked about the budget", glossary: Glossary(concepts: ["meshcore"]))

    #expect(found.isEmpty)
}

@Test func aTermOnlyInTheTranscriptIsNotACorrection() {
    let found = corrections(summary: "Talked about the roof.", transcript: "we use mesh core on the roof", glossary: Glossary(concepts: ["meshcore"]))

    #expect(found.isEmpty)
}

@Test func aTermInsideALongerWordOfTheSummaryDoesNotCount() {
    let found = corrections(summary: "Uses meshcorexyz.", transcript: "we use mesh core", glossary: Glossary(concepts: ["meshcore"]))

    #expect(found.isEmpty)
}

@Test func aSummaryNameThatCompletesATranscriptFirstNameIsNotACorrection() {
    let found = corrections(summary: "[[Ben Smith]] agreed.", transcript: "Speaker_1: Ben agreed", glossary: Glossary(people: ["Ben Smith"]))

    #expect(found.isEmpty)
}

@Test func aPluralOfTheTermInTheTranscriptIsNotACorrection() {
    let found = corrections(summary: "Set up [[packet radio]].", transcript: "we set up packet radios", glossary: Glossary(concepts: ["packet radio"]))

    #expect(found.isEmpty)
}

@Test func anEdFormOfTheTermInTheTranscriptIsNotACorrection() {
    let found = corrections(summary: "Set up [[provision]].", transcript: "we provisioned the nodes", glossary: Glossary(concepts: ["provision"]))

    #expect(found.isEmpty)
}

@Test func aSuffixedTranscriptFormIsSkippedButATrueManglingOfTheSameTermStillCounts() throws {
    let glossary = Glossary(concepts: ["meshcore"])

    #expect(corrections(summary: "Uses [[meshcore]].", transcript: "we use meshcored nodes", glossary: glossary).isEmpty)
    #expect(try #require(corrections(summary: "Uses [[meshcore]].", transcript: "we use meshcor nodes", glossary: glossary).first).originalSpan == "meshcor")
    #expect(try #require(corrections(summary: "Uses [[meshcore]].", transcript: "we use mesh core nodes", glossary: glossary).first).originalSpan == "mesh core")
}

@Test func severalCorrectionsComeBackInSummaryOrderWithUniqueDeterministicIds() {
    let summary = "[[packet radio]] and [[meshcore]] and [[Priya Patel]]."
    let transcript = "we used packet radeo and mesh core, ask Pria Patel"
    let glossary = Glossary(people: ["Priya Patel"], concepts: ["meshcore", "packet radio"])

    let first = corrections(summary: summary, transcript: transcript, glossary: glossary)
    let second = corrections(summary: summary, transcript: transcript, glossary: glossary)

    #expect(first.map(\.correctedSpan) == ["packet radio", "meshcore", "Priya Patel"])
    #expect(first.map(\.originalSpan) == ["packet radeo", "mesh core", "Pria Patel"])
    #expect(Set(first.map(\.suggestionId)).count == 3)
    #expect(first == second)
}

@Test func aTermListedInTwoCategoriesIsCorrectedOnce() {
    let glossary = Glossary(projects: ["meshcore"], concepts: ["Meshcore"])

    let found = corrections(summary: "Uses [[meshcore]].", transcript: "we use mesh core", glossary: glossary)

    #expect(found.count == 1)
}

@Test func theStrategyEntryPointReturnsTheSameCorrections() async throws {
    let draft = SummaryDraft(summaryText: "Uses [[meshcore]].", transcriptText: "we use mesh core")
    let glossary = Glossary(concepts: ["meshcore"])

    let viaProtocol = try await GlossaryJargonCorrector().correct(summary: draft, glossary: glossary)

    #expect(viaProtocol == corrections(summary: draft.summaryText, transcript: draft.transcriptText, glossary: glossary))
    #expect(viaProtocol.count == 1)
}
