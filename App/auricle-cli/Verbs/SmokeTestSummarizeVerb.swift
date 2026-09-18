import ArgumentParser
import ClaudeSummarizer
import Core
import Foundation
import Summarize
import SummarizerInterface

/// Decision 3.6's smoke-test rig, run by hand via Tests/scripts/run-smoke-test.sh.
/// Not a user-facing verb: `shouldDisplay: false` keeps it out of `auricle help`
/// and shell completion. It spends real Anthropic API credit — one call per
/// transcript per arm — so it refuses to start before any call is made when
/// there is nothing to run, and states the planned call count first. The logic
/// lives in `Summarize` (covered by `swift test`); this file only parses
/// arguments, wires the arms, and calls it. It is one of the composition roots
/// `.swiftlint.yml` allows to name a concrete strategy.
struct SmokeTestSummarizeVerb: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__smoke-test-summarize",
        abstract: "Run the Citations and substring summarizers over real transcripts and write comparison reports.",
        shouldDisplay: false,
    )

    @Option(help: "Directory of CanonicalTranscript .json fixtures.")
    var transcripts: String

    @Option(help: "Directory to write results.md (metrics only) and detail.md (real meeting content) into.")
    var output: String

    func run() async throws {
        let transcriptsDirectory = Self.directoryURL(transcripts)
        let outputDirectory = Self.directoryURL(output)

        let fixtures: [SmokeTestFixture]
        do {
            fixtures = try SmokeTestFixtureLoader.load(from: transcriptsDirectory)
        } catch let error as SmokeTestFixtureLoader.LoadError {
            writeStderr("__smoke-test-summarize: \(error.localizedDescription)")
            throw ExitCode(1)
        }

        // Created before any paid call: an unwritable --output must fail here,
        // not after every result has been paid for and would be discarded.
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        } catch {
            writeStderr("__smoke-test-summarize: cannot create the output directory \(outputDirectory.path).")
            throw ExitCode(1)
        }

        let runner = SmokeTestRunner(arms: [
            SmokeTestArm(label: "citations", strategy: ClaudeCitationsSummarizer()),
            SmokeTestArm(label: "substring", strategy: ClaudeSubstringSummarizer()),
        ])
        let config = SummarizerConfig()
        let plannedCalls = runner.plannedCallCount(fixtureCount: fixtures.count)
        writeStderr(
            "__smoke-test-summarize: \(plannedCalls) live Anthropic API call(s) planned "
                + "(\(fixtures.count) transcript(s) x \(runner.armCount) arm(s), model \(config.modelIdentifier)).",
        )

        let rows = await runner.run(fixtures: fixtures, glossary: Glossary(), config: config) { completed, total in
            writeStderr("__smoke-test-summarize: transcript \(completed) of \(total) done.")
        }

        let failedArmCount = rows.flatMap(\.arms).count { $0.failureReason != nil }
        if failedArmCount > 0 {
            writeStderr("__smoke-test-summarize: \(failedArmCount) of \(plannedCalls) arm run(s) failed; the reports record each failure.")
        }

        do {
            let paths = try SmokeTestReportWriter.write(
                rows: rows,
                generatedAt: Date(),
                modelIdentifier: config.modelIdentifier,
                to: outputDirectory,
            )
            print("metrics (no item text or quotes; fixture file names appear as given, so name fixtures neutrally before committing): \(paths.metrics.path)")
            print("detail (real meeting content, never commit): \(paths.detail.path)")
        } catch {
            writeStderr("__smoke-test-summarize: could not write the reports: \(error)")
            throw ExitCode(1)
        }

        // Every arm failing (a missing Keychain key, say) produced no
        // comparison at all; a partial failure is itself a result.
        if failedArmCount == plannedCalls {
            throw ExitCode(1)
        }
    }

    private static func directoryURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}
