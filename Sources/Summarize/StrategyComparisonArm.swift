import SummarizerInterface

/// One column of a strategy comparison: a label the reports print plus the
/// strategy that produces it. The rig compares arms, not a fixed strategy
/// pair, so the same run also answers "is prompt B better than prompt A" —
/// two arms of the same strategy type, distinguished only by their label and
/// whatever prompt input each was constructed with.
public struct StrategyComparisonArm: Sendable {
    public let label: String
    public let strategy: any SummarizerStrategy

    public init(label: String, strategy: any SummarizerStrategy) {
        self.label = label
        self.strategy = strategy
    }
}
