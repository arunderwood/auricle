import SummarizerInterface
import Testing

@Test func summarizerConfigDefaultInitUsesLockedDefaults() {
    let config = SummarizerConfig()

    #expect(config.modelIdentifier == "claude-opus-5")
    #expect(config.effortLevel == .medium)
    #expect(config.promptCachingEnabled)
    #expect(config.remainingCostBudgetUSD == nil)
}

@Test func summarizerConfigMemberwiseInitRoundTripsAndSupportsEquatable() {
    let config = SummarizerConfig(
        modelIdentifier: "claude-haiku-4-5",
        effortLevel: .high,
        promptCachingEnabled: false,
        remainingCostBudgetUSD: 0.12,
    )

    #expect(config.modelIdentifier == "claude-haiku-4-5")
    #expect(config.effortLevel == .high)
    #expect(!config.promptCachingEnabled)
    #expect(config.remainingCostBudgetUSD == 0.12)

    let identical = SummarizerConfig(
        modelIdentifier: "claude-haiku-4-5",
        effortLevel: .high,
        promptCachingEnabled: false,
        remainingCostBudgetUSD: 0.12,
    )
    #expect(config == identical)
    #expect(config != SummarizerConfig())
}
