/// The shape every `SummarizerStrategy` (Citations, substring, future
/// local-LLM) produces identically — no strategy-specific "raw response"
/// field. The renderer and validator are grounding-method-agnostic by
/// construction (AR-PAT-7 LSP).
public struct SummaryWithGrounding: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let summary: String
    public let actionItems: [GroundedItem]
    public let decisions: [GroundedItem]
    public let groundingMethod: GroundingMethod
    public let cost: SummarizerCost
    /// Items the strategy discarded because their grounding did not validate.
    /// A strategy that fails the whole call on any grounding failure (Citations)
    /// reports 0 here; the signal for that strategy is the thrown error.
    public let quoteValidationDropCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case summary
        case actionItems = "action_items"
        case decisions
        case groundingMethod = "grounding_method"
        case cost
        case quoteValidationDropCount = "quote_validation_drop_count"
    }

    public init(
        schemaVersion: Int,
        summary: String,
        actionItems: [GroundedItem],
        decisions: [GroundedItem],
        groundingMethod: GroundingMethod,
        cost: SummarizerCost,
        quoteValidationDropCount: Int,
    ) {
        self.schemaVersion = schemaVersion
        self.summary = summary
        self.actionItems = actionItems
        self.decisions = decisions
        self.groundingMethod = groundingMethod
        self.cost = cost
        self.quoteValidationDropCount = quoteValidationDropCount
    }
}

public struct SummarizerCost: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let thinkingTokens: Int
    public let costUSD: Double

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case thinkingTokens = "thinking_tokens"
        case costUSD = "cost_usd"
    }

    public init(inputTokens: Int, outputTokens: Int, thinkingTokens: Int, costUSD: Double) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thinkingTokens = thinkingTokens
        self.costUSD = costUSD
    }
}
