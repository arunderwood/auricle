@testable import AIReviewerInterface
import Core
import Foundation
import Testing

@Test func jargonCorrectionRoundTripsThroughSnakeCaseJSON() throws {
    let value = JargonCorrection(
        suggestionId: "jargon-3-11",
        reasoning: "The vault glossary has \"meshcore\".",
        charRange: ByteRange(start: 3, end: 11),
        originalSpan: "mesh core",
        correctedSpan: "meshcore",
    )

    let data = try JSONEncoder().encode(value)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(json.keys) == ["suggestion_id", "reasoning", "char_range", "original_span", "corrected_span"])
    let range = try #require(json["char_range"] as? [String: Int])
    #expect(range == ["start": 3, "end": 11])

    #expect(try JSONDecoder().decode(JargonCorrection.self, from: data) == value)
}

@Test func aStrategyReceivesTheSummaryDraftAndTheGlossary() async throws {
    struct Echo: JargonCorrectionStrategy {
        func correct(summary: SummaryDraft, glossary: Glossary) async throws -> [JargonCorrection] {
            let correction = JargonCorrection(
                suggestionId: "echo",
                reasoning: summary.transcriptText,
                charRange: ByteRange(start: 0, end: summary.summaryText.utf8.count),
                originalSpan: glossary.concepts.joined(),
                correctedSpan: summary.summaryText,
            )
            return [correction]
        }
    }
    let strategy: any JargonCorrectionStrategy = Echo()

    let result = try await strategy.correct(
        summary: SummaryDraft(summaryText: "sum", transcriptText: "tr"),
        glossary: Glossary(concepts: ["c"]),
    )

    #expect(result.map(\.reasoning) == ["tr"])
    #expect(result.map(\.originalSpan) == ["c"])
}
