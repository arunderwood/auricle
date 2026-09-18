/// No API-key field: Keychain is read at call time (`KeychainAPIKey.read()`),
/// never carried in this value.
public struct SummarizerConfig: Sendable, Equatable {
    public let modelIdentifier: String
    public let effortLevel: EffortLevel
    public let promptCachingEnabled: Bool
    /// Passed to the fallback strategy by the orchestrator so a fallback call
    /// stays within the per-meeting cost ceiling the primary call already
    /// spent part of.
    public let remainingCostBudgetUSD: Double?

    public init(
        modelIdentifier: String = "claude-opus-5",
        effortLevel: EffortLevel = .medium,
        promptCachingEnabled: Bool = true,
        remainingCostBudgetUSD: Double? = nil,
    ) {
        self.modelIdentifier = modelIdentifier
        self.effortLevel = effortLevel
        self.promptCachingEnabled = promptCachingEnabled
        self.remainingCostBudgetUSD = remainingCostBudgetUSD
    }
}

public enum EffortLevel: String, Sendable, Codable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max
}
