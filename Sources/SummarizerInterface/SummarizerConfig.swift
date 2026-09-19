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
    /// Display names of the meeting's attendees, rendered into the prompt.
    /// Names only: the strategy protocol has no `Meeting` parameter, and an
    /// attendee's email must never reach a prompt. Empty when the meeting has
    /// no matched calendar event.
    public private(set) var attendeeNames: [String]

    public init(
        modelIdentifier: String = "claude-opus-5",
        effortLevel: EffortLevel = .medium,
        promptCachingEnabled: Bool = true,
        remainingCostBudgetUSD: Double? = nil,
        attendeeNames: [String] = [],
    ) {
        self.modelIdentifier = modelIdentifier
        self.effortLevel = effortLevel
        self.promptCachingEnabled = promptCachingEnabled
        self.remainingCostBudgetUSD = remainingCostBudgetUSD
        self.attendeeNames = attendeeNames
    }

    /// A copy differing only in `attendeeNames`, so a caller that resolves
    /// attendees after the config was built cannot drop another field.
    public func withAttendeeNames(_ attendeeNames: [String]) -> SummarizerConfig {
        var copy = self
        copy.attendeeNames = attendeeNames
        return copy
    }
}

public enum EffortLevel: String, Sendable, Codable, CaseIterable {
    case low
    case medium
    case high
    case xhigh
    case max
}
