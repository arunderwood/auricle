import Foundation
import SummarizerInterface
import Testing

@Test func summaryWithGroundingRoundTripsAndUsesSnakeCaseKeys() throws {
    let value = SummaryWithGrounding(
        schemaVersion: 1,
        summary: "The team discussed the roadmap.",
        actionItems: [
            GroundedItem(
                text: "Ship the release notes",
                grounding: GroundingPointer(transcriptStart: 0, transcriptEnd: 10, sourceMethod: .citations),
            ),
        ],
        decisions: [
            GroundedItem(
                text: "Adopt the new schema",
                grounding: GroundingPointer(transcriptStart: 11, transcriptEnd: 20, sourceMethod: .substring),
            ),
        ],
        groundingMethod: .citations,
        cost: SummarizerCost(inputTokens: 100, outputTokens: 50, thinkingTokens: 10, costUSD: 0.05),
        quoteValidationDropCount: 3,
    )

    let data = try JSONEncoder().encode(value)
    let json = try #require(String(data: data, encoding: .utf8))

    #expect(json.contains("\"schema_version\""))
    #expect(json.contains("\"action_items\""))
    #expect(json.contains("\"grounding_method\""))
    #expect(json.contains("\"transcript_start\""))
    #expect(json.contains("\"transcript_end\""))
    #expect(json.contains("\"source_method\""))
    #expect(json.contains("\"input_tokens\""))
    #expect(json.contains("\"output_tokens\""))
    #expect(json.contains("\"thinking_tokens\""))
    #expect(json.contains("\"cost_usd\""))
    #expect(json.contains("\"quote_validation_drop_count\""))

    #expect(!json.contains("\"schemaVersion\""))
    #expect(!json.contains("\"actionItems\""))
    #expect(!json.contains("\"groundingMethod\""))
    #expect(!json.contains("\"transcriptStart\""))
    #expect(!json.contains("\"transcriptEnd\""))
    #expect(!json.contains("\"sourceMethod\""))
    #expect(!json.contains("\"inputTokens\""))
    #expect(!json.contains("\"outputTokens\""))
    #expect(!json.contains("\"thinkingTokens\""))
    #expect(!json.contains("\"costUSD\""))
    #expect(!json.contains("\"quoteValidationDropCount\""))

    let decoded = try JSONDecoder().decode(SummaryWithGrounding.self, from: data)
    #expect(decoded == value)
    #expect(decoded.quoteValidationDropCount == 3)
}
