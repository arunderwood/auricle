import Core
import Foundation
import Persist
import Summarize
import SummarizerInterface

/// One arm's result for one meeting. A row either carries a score or a
/// failure reason: an arm that threw, a note that could not be rendered or
/// written, and a scorer that refused all land here so the rest of the run
/// still produces numbers.
public struct RecallBenchRow: Sendable, Equatable {
    public let arm: String
    public let meeting: String
    public let score: RecallBenchScore?
    public let costUSD: Double
    public let failureReason: String?

    public init(arm: String, meeting: String, score: RecallBenchScore?, costUSD: Double, failureReason: String?) {
        self.arm = arm
        self.meeting = meeting
        self.score = score
        self.costUSD = costUSD
        self.failureReason = failureReason
    }
}

public struct RecallBenchResult: Sendable {
    public let rows: [RecallBenchRow]
    /// Wall clock over the whole run. No summarizer result carries a latency,
    /// so the bench measures its own.
    public let elapsed: Duration

    public init(rows: [RecallBenchRow], elapsed: Duration) {
        self.rows = rows
        self.elapsed = elapsed
    }
}

/// The offline recall loop: frozen transcript in, real summarizer call per
/// arm, shipped note out, `score.py` number back. No audio, no state
/// database, no vault — every file it writes lands under `workingDirectory`.
public enum RecallBenchRunner {
    public static func run(
        fixtures: [RecallBenchFixture],
        arms: [StrategyComparisonArm],
        scorer: RecallBenchScorer,
        workingDirectory: URL,
        config: SummarizerConfig = SummarizerConfig(),
        glossary: Glossary = Glossary(),
        progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil,
    ) async -> RecallBenchResult {
        let clock = ContinuousClock()
        let start = clock.now
        let comparison = await StrategyComparisonRunner(arms: arms).run(
            fixtures: fixtures.map { StrategyComparisonFixture(name: $0.id, transcript: $0.transcript) },
            glossary: glossary,
            config: config,
            progress: progress,
        )

        var rows: [RecallBenchRow] = []
        for (fixture, comparisonRow) in zip(fixtures, comparison) {
            for armResult in comparisonRow.arms {
                await rows.append(row(for: armResult, fixture: fixture, scorer: scorer, workingDirectory: workingDirectory))
            }
        }
        return RecallBenchResult(rows: rows, elapsed: clock.now - start)
    }

    private static func row(
        for armResult: StrategyComparisonArmResult,
        fixture: RecallBenchFixture,
        scorer: RecallBenchScorer,
        workingDirectory: URL,
    ) async -> RecallBenchRow {
        guard case let .summary(grounded) = armResult.outcome else {
            return RecallBenchRow(
                arm: armResult.label,
                meeting: fixture.id,
                score: nil,
                costUSD: 0,
                failureReason: armResult.failureReason,
            )
        }
        do {
            let notePath = try writeNote(grounded, fixture: fixture, arm: armResult.label, workingDirectory: workingDirectory)
            let score = try await scorer.score(
                notePath: notePath,
                expectedPath: fixture.directory.appendingPathComponent("expected.json"),
                transcriptPath: fixture.directory.appendingPathComponent("transcript.json"),
            )
            return RecallBenchRow(
                arm: armResult.label,
                meeting: fixture.id,
                score: score,
                costUSD: grounded.cost.costUSD,
                failureReason: nil,
            )
        } catch {
            // The call is already paid for, so its cost is recorded even
            // though the row has no score.
            return RecallBenchRow(
                arm: armResult.label,
                meeting: fixture.id,
                score: nil,
                costUSD: grounded.cost.costUSD,
                failureReason: reason(for: error),
            )
        }
    }

    /// The shipped rendering path, end to end: the artifact mapper, the
    /// artifact→frontmatter mapping and the frontmatter renderer, so the note
    /// the scorer parses is byte-identical in shape to a published one.
    static func renderNote(_ grounded: SummaryWithGrounding, fixture: RecallBenchFixture) throws -> String {
        let artifact = try OfflineSummaryArtifact.artifact(
            title: fixture.id,
            transcript: fixture.transcript,
            grounded: grounded,
        )
        return FrontmatterRenderer.render(meeting: SummaryArtifactFrontmatter.meeting(
            artifact,
            meetingID: MeetingID.generate(),
            date: dateFormatter.string(from: Date()),
            supersedes: nil,
        ))
    }

    private static func writeNote(
        _ grounded: SummaryWithGrounding,
        fixture: RecallBenchFixture,
        arm: String,
        workingDirectory: URL,
    ) throws -> URL {
        let armDirectory = workingDirectory.appendingPathComponent(slug(arm), isDirectory: true)
        try FileManager.default.createDirectory(at: armDirectory, withIntermediateDirectories: true)
        let notePath = armDirectory.appendingPathComponent("\(slug(fixture.id)).md")
        try AtomicWriter.write(Data(renderNote(grounded, fixture: fixture).utf8), to: notePath)
        return notePath
    }

    /// An arm label carries the strategy's prompt directory (`substring:v2`),
    /// so it reaches the filesystem only as a single flat path component —
    /// never a `/` that would place a note outside the working directory.
    static func slug(_ label: String) -> String {
        let cleaned = label.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        }
        return String(cleaned)
    }

    /// Same discipline as `StrategyComparisonRunner.failureReason`: the type
    /// or the localized description of an error this module raised, never an
    /// arbitrary error's description, which can embed transcript text.
    private static func reason(for error: any Error) -> String {
        switch error {
        case let error as RecallBenchScorer.ScoreError:
            error.errorDescription ?? String(describing: error)
        default:
            String(describing: type(of: error))
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
