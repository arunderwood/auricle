import Core

/// Every arm's result for one transcript, in the order the arms were given.
/// Carries the transcript itself so the detail report can slice each item's
/// source quote from `transcript.text` by its grounding range.
public struct SmokeTestRow: Sendable, Equatable {
    public let name: String
    public let transcript: CanonicalTranscript
    public let arms: [SmokeTestArmResult]

    public init(name: String, transcript: CanonicalTranscript, arms: [SmokeTestArmResult]) {
        self.name = name
        self.transcript = transcript
        self.arms = arms
    }
}
