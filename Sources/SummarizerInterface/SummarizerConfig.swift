/// No API-key field: Keychain is read at call time (`KeychainAPIKey.read()`),
/// never carried in this value.
public struct SummarizerConfig: Sendable, Equatable {
    public let modelIdentifier: String
    /// Sent to the Messages API as `output_config.effort`, so it is also what
    /// telemetry records. The API's own default is `high`, not this type's.
    public let effortLevel: EffortLevel
    public let promptCachingEnabled: Bool
    /// NFR-C1's per-meeting ceiling for a 30-minute meeting on the default
    /// tier. Not enforced: the stage records whether the call's cost passed
    /// it and warns, and keeps the summary.
    public let costCeilingUSD: Double
    /// Display names of the meeting's attendees, rendered into the prompt.
    /// Names only: the strategy protocol has no `Meeting` parameter, and an
    /// attendee's email must never reach a prompt. Empty when the meeting has
    /// no matched calendar event.
    public private(set) var attendeeNames: [String]

    public init(
        modelIdentifier: String = "claude-opus-5",
        effortLevel: EffortLevel = .medium,
        promptCachingEnabled: Bool = true,
        costCeilingUSD: Double = 0.50,
        attendeeNames: [String] = [],
    ) {
        self.modelIdentifier = modelIdentifier
        self.effortLevel = effortLevel
        self.promptCachingEnabled = promptCachingEnabled
        self.costCeilingUSD = costCeilingUSD
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
