import SummarizerInterface

/// What one arm did with one transcript. A failure carries a reason string
/// naming the error case or type only — an arm's error message can embed
/// transcript text or provider response content, and the reports this feeds
/// include a file that is committed.
public struct StrategyComparisonArmResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        case summary(SummaryWithGrounding)
        case failure(reason: String)
    }

    public let label: String
    public let outcome: Outcome

    public init(label: String, outcome: Outcome) {
        self.label = label
        self.outcome = outcome
    }

    /// Non-nil exactly when the arm threw.
    public var failureReason: String? {
        if case let .failure(reason) = outcome {
            return reason
        }
        return nil
    }
}
