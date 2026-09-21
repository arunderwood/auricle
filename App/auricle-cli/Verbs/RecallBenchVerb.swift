import ArgumentParser
import ClaudeSummarizer
import Core
import Foundation
import RecallBench
import Summarize
import SummarizerInterface

/// Story 4.11's offline recall bench, run by hand via
/// Tests/scripts/run-recall-bench.sh. Not user-facing: `shouldDisplay: false`
/// keeps it out of `auricle help` and shell completion. It spends real
/// Anthropic API credit — one call per frozen transcript per arm — and reads
/// no audio, no state database and no vault. The logic lives in
/// `Sources/RecallBench` (covered by `swift test`); this file only parses
/// arguments, wires the arms and prints the report. It is one of the
/// composition roots `.swiftlint.yml` allows to name a concrete strategy.
struct RecallBenchVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__recall-bench",
        abstract: "Summarize the frozen AMI reference transcripts with one or more arms and score item recall offline.",
        shouldDisplay: false,
    )

    @Option(help: "Repository root holding Tests/regression/ami/manifest.json and the reference fixtures it names.")
    var repoRoot: String

    @Option(help: "Directory the rendered notes are written into. Nothing outside it is written.")
    var output: String

    @Option(
        name: .customLong("arm"),
        help: "An arm to run: citations, substring, or substring:<absolute prompt dir>. Repeat for several. Default: citations and substring.",
    )
    var arms: [String] = []

    func run() async throws {
        let repoRootURL = Self.directoryURL(repoRoot)
        let outputDirectory = Self.directoryURL(output)
        let specs = try Self.parseArms(arms)

        let fixtures: [RecallBenchFixture]
        do {
            fixtures = try RecallBenchFixtureLoader.load(repoRoot: repoRootURL)
        } catch let error as RecallBenchFixtureLoader.LoadError {
            writeStderr("__recall-bench: \(error.localizedDescription)")
            throw ExitCode(1)
        }

        // Everything that would make every row fail is checked before the
        // first paid call, not discovered after the whole set is spent.
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            writeStderr("__recall-bench: cannot create the output directory \(outputDirectory.path).")
            throw ExitCode(1)
        }

        let scriptURL = repoRootURL.appendingPathComponent(Self.scorerPath)
        guard FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            writeStderr("__recall-bench: cannot read the scorer at \(scriptURL.path).")
            throw ExitCode(1)
        }
        guard Self.python3IsAvailable() else {
            writeStderr("__recall-bench: python3 is not on PATH, so nothing could be scored.")
            throw ExitCode(1)
        }

        let config = SummarizerConfig()
        let plannedCalls = fixtures.count * specs.count
        writeStderr(
            "__recall-bench: \(plannedCalls) live Anthropic API call(s) planned "
                + "(\(fixtures.count) transcript(s) x \(specs.count) arm(s), model \(config.modelIdentifier)).",
        )

        let result = await RecallBenchRunner.run(
            fixtures: fixtures,
            arms: specs.map(Self.arm(for:)),
            scorer: RecallBenchScorer(scriptURL: scriptURL),
            workingDirectory: outputDirectory,
            config: config,
        ) { completed, total in
            writeStderr("__recall-bench: transcript \(completed) of \(total) summarized.")
        }

        print(RecallBenchReportRenderer.render(rows: result.rows, elapsed: result.elapsed), terminator: "")

        // Every row failing (a missing Keychain key, say) produced no
        // measurement at all; a partial failure is itself a result.
        if result.rows.allSatisfy({ $0.failureReason != nil }) {
            throw ExitCode(1)
        }
    }

    private static func parseArms(_ raw: [String]) throws -> [StrategyComparisonArmSpec] {
        do {
            return try StrategyComparisonArmSpec.parseAll(raw)
        } catch {
            writeStderr("__recall-bench: \(error.localizedDescription)")
            throw ExitCode(1)
        }
    }

    private static func arm(for spec: StrategyComparisonArmSpec) -> StrategyComparisonArm {
        switch spec.kind {
        case .citations:
            StrategyComparisonArm(label: spec.label, strategy: ClaudeCitationsSummarizer())
        case .substring:
            StrategyComparisonArm(label: spec.label, strategy: ClaudeSubstringSummarizer(promptDir: spec.promptDir))
        }
    }

    private static let scorerPath = "Tests/regression/ami/score.py"

    /// Decided by looking rather than by running. `run()` is async, and
    /// waiting on a subprocess there blocks a cooperative-pool thread; the
    /// same shape deadlocked the test suite on a four-core runner. A `PATH`
    /// walk answers the question the preflight is asking — is there anything
    /// to score with — without spawning anything.
    private static func python3IsAvailable() -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        return path.split(separator: ":").contains { directory in
            FileManager.default.isExecutableFile(atPath: "\(directory)/python3")
        }
    }

    private static func directoryURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}
