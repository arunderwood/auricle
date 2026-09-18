import Core
import SummarizerInterface

/// Runs every arm over every fixture and records what each returned. Depends
/// only on `SummarizerStrategy` (via `StrategyComparisonArm`), so it never names a
/// concrete strategy; the composition root decides which arms exist.
public struct StrategyComparisonRunner: Sendable {
    private let arms: [StrategyComparisonArm]

    public init(arms: [StrategyComparisonArm]) {
        self.arms = arms
    }

    public var armCount: Int {
        arms.count
    }

    /// Counts logical strategy calls: one per arm per transcript, before any
    /// HTTP-layer retries. The HTTP client retries transient failures within
    /// its own budget, so the requests actually sent can exceed this number.
    /// The caller announces it before starting.
    public func plannedCallCount(fixtureCount: Int) -> Int {
        fixtureCount * arms.count
    }

    /// Transcripts run one after another, so a run never has more than one
    /// call per arm in flight; the arms of a single transcript run
    /// concurrently. Results follow the order of `fixtures` and of the arms
    /// the runner was built with, regardless of which arm finished first.
    /// An arm that throws is recorded as a failure and the run continues:
    /// `run` itself never throws.
    ///
    /// `progress` receives (transcripts completed, transcripts total) after
    /// each transcript.
    public func run(
        fixtures: [StrategyComparisonFixture],
        glossary: Glossary,
        config: SummarizerConfig,
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil,
    ) async -> [StrategyComparisonRow] {
        var rows: [StrategyComparisonRow] = []
        for fixture in fixtures {
            let results = await runArms(on: fixture.transcript, glossary: glossary, config: config)
            rows.append(StrategyComparisonRow(name: fixture.name, transcript: fixture.transcript, arms: results))
            progress?(rows.count, fixtures.count)
        }
        return rows
    }

    private func runArms(
        on transcript: CanonicalTranscript,
        glossary: Glossary,
        config: SummarizerConfig,
    ) async -> [StrategyComparisonArmResult] {
        await withTaskGroup(of: (index: Int, result: StrategyComparisonArmResult).self) { group in
            for (index, arm) in arms.enumerated() {
                group.addTask {
                    let result = await Self.runArm(arm, on: transcript, glossary: glossary, config: config)
                    return (index, result)
                }
            }
            var indexed: [(index: Int, result: StrategyComparisonArmResult)] = []
            for await entry in group {
                indexed.append(entry)
            }
            return indexed.sorted { $0.index < $1.index }.map(\.result)
        }
    }

    private static func runArm(
        _ arm: StrategyComparisonArm,
        on transcript: CanonicalTranscript,
        glossary: Glossary,
        config: SummarizerConfig,
    ) async -> StrategyComparisonArmResult {
        do {
            let summary = try await arm.strategy.summarize(transcript: transcript, glossary: glossary, config: config)
            return StrategyComparisonArmResult(label: arm.label, outcome: .summary(summary))
        } catch {
            return StrategyComparisonArmResult(label: arm.label, outcome: .failure(reason: failureReason(for: error)))
        }
    }

    /// Names the `SummarizerError` case, or for any other error only its
    /// type: `localizedDescription` and `String(describing:)` on an arbitrary
    /// error can carry a response body or transcript fragment.
    static func failureReason(for error: any Error) -> String {
        if let summarizerError = error as? SummarizerError {
            return "SummarizerError.\(summarizerError)"
        }
        return String(describing: type(of: error))
    }
}
