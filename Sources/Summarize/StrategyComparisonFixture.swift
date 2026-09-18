import Core

/// One transcript the comparison runs every arm against. `name` is the
/// fixture file's stem, which is the only identifier the reports print for it.
public struct StrategyComparisonFixture: Sendable, Equatable {
    public let name: String
    public let transcript: CanonicalTranscript

    public init(name: String, transcript: CanonicalTranscript) {
        self.name = name
        self.transcript = transcript
    }
}
