/// What one reviewer call cost. A local model reports `costUSD: 0` and
/// `modelID: "local:<name>"`, so the telemetry columns need no migration.
public struct AIReviewerCost: Codable, Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let costUSD: Double
    public let modelID: String

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case costUSD = "cost_usd"
        case modelID = "model_id"
    }

    public init(inputTokens: Int, outputTokens: Int, costUSD: Double, modelID: String) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costUSD = costUSD
        self.modelID = modelID
    }
}
