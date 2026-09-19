import SummarizerInterface
import Testing

@Test func summarizerConfigDefaultInitUsesLockedDefaults() {
    let config = SummarizerConfig()

    #expect(config.modelIdentifier == "claude-opus-5")
    #expect(config.effortLevel == .medium)
    #expect(config.promptCachingEnabled)
    #expect(config.costCeilingUSD == 0.50)
    #expect(config.attendeeNames.isEmpty)
}

@Test func summarizerConfigMemberwiseInitRoundTripsAndSupportsEquatable() {
    let config = SummarizerConfig(
        modelIdentifier: "claude-haiku-4-5",
        effortLevel: .high,
        promptCachingEnabled: false,
        costCeilingUSD: 0.12,
    )

    #expect(config.modelIdentifier == "claude-haiku-4-5")
    #expect(config.effortLevel == .high)
    #expect(!config.promptCachingEnabled)
    #expect(config.costCeilingUSD == 0.12)

    let identical = SummarizerConfig(
        modelIdentifier: "claude-haiku-4-5",
        effortLevel: .high,
        promptCachingEnabled: false,
        costCeilingUSD: 0.12,
    )
    #expect(config == identical)
    #expect(config != SummarizerConfig())
}

@Test func withAttendeeNamesReplacesOnlyTheNames() {
    let config = SummarizerConfig(
        modelIdentifier: "claude-haiku-4-5",
        effortLevel: .high,
        promptCachingEnabled: false,
        costCeilingUSD: 0.12,
        attendeeNames: ["Old Name"],
    )

    let replaced = config.withAttendeeNames(["Ada Lovelace"])

    #expect(replaced == SummarizerConfig(
        modelIdentifier: "claude-haiku-4-5",
        effortLevel: .high,
        promptCachingEnabled: false,
        costCeilingUSD: 0.12,
        attendeeNames: ["Ada Lovelace"],
    ))
    #expect(replaced != config)
}
