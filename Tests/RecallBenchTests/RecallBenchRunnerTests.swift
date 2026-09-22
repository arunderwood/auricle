import Foundation
import RecallBench
import Summarize
import Testing

private let widgetTranscript = makeTranscript([
    (speaker: "Speaker_1", body: "We will ship the widget on Friday without fail."),
    (speaker: "Speaker_2", body: "Agreed, Friday is the date we are committing to."),
])

private func benchFixture(id: String = "ES0001a", directory: URL) -> RecallBenchFixture {
    RecallBenchFixture(id: id, directory: directory, transcript: widgetTranscript)
}

private let passingScore = RecallBenchScore(keptItems: 2, ungroundedQuotes: 0, expectedItems: 2, recalledItems: 2, falseKeeps: 0)

private func stubScorer(
    _ capture: (@Sendable (URL, [String]) -> Void)? = nil,
) -> RecallBenchScorer {
    RecallBenchScorer(scriptURL: URL(fileURLWithPath: "/nowhere/score.py")) { url, arguments in
        capture?(url, arguments)
        return try JSONEncoder().encode([
            "kept_items": passingScore.keptItems,
            "ungrounded_quotes": passingScore.ungroundedQuotes,
            "expected_items": passingScore.expectedItems,
            "recalled_items": passingScore.recalledItems,
            "false_keeps": passingScore.falseKeeps,
        ])
    }
}

@Test
func rendersTheShippedNoteAndScoresItPerArm() async throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    let workingDirectory = root.url.appendingPathComponent("work", isDirectory: true)
    let summary = makeSummary(
        actionItems: [groundedItem("Ship the widget on Friday", of: widgetTranscript, utterance: 0)],
        decisions: [groundedItem("Friday is the ship date", of: widgetTranscript, utterance: 1)],
        costUSD: 0.0421,
    )
    let arm = StrategyComparisonArm(label: "substring:recall-v2", strategy: StubSummarizer(result: .success(summary)))

    let result = await RecallBenchRunner.run(
        fixtures: [benchFixture(directory: root.url)],
        arms: [arm],
        scorer: stubScorer(),
        workingDirectory: workingDirectory,
    )

    let row = try #require(result.rows.first)
    #expect(result.rows.count == 1)
    #expect(row.arm == "substring:recall-v2")
    #expect(row.meeting == "ES0001a")
    #expect(row.score == passingScore)
    #expect(row.costUSD == 0.0421)
    #expect(row.failureReason == nil)
    #expect(result.elapsed > .zero)

    // The arm's `:` never reaches the filesystem as a path separator.
    let note = try String(contentsOf: workingDirectory.appendingPathComponent("substring-recall-v2/ES0001a.md"), encoding: .utf8)
    #expect(note.contains("## Action Items\n\n- Ship the widget on Friday\n  > Speaker_1: We will ship the widget on Friday without fail."))
    #expect(note.contains("## Decisions\n\n- Friday is the ship date\n  > Speaker_2: Agreed, Friday is the date we are committing to."))
}

@Test
func writesNothingOutsideTheWorkingDirectory() async throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    let workingDirectory = root.url.appendingPathComponent("work", isDirectory: true)
    let summary = makeSummary(actionItems: [groundedItem("Ship it", of: widgetTranscript, utterance: 0)], costUSD: 0.01)
    // An absolute prompt directory under the temporary root, so the escape
    // this test is named for would land somewhere the test can see it is not.
    let escapeTarget = root.url.appendingPathComponent("escape", isDirectory: true)
    let arms = [
        StrategyComparisonArm(label: "citations", strategy: StubSummarizer(result: .success(summary))),
        StrategyComparisonArm(label: "substring:\(escapeTarget.path)", strategy: StubSummarizer(result: .success(summary))),
    ]

    _ = await RecallBenchRunner.run(
        fixtures: [benchFixture(directory: root.url)],
        arms: arms,
        scorer: stubScorer(),
        workingDirectory: workingDirectory,
    )

    #expect(!FileManager.default.fileExists(atPath: escapeTarget.path))
    let written = filePaths(under: root.url)
    let prefix = workingDirectory.resolvingSymlinksInPath().path + "/"
    #expect(!written.isEmpty)
    #expect(written.allSatisfy { $0.hasPrefix(prefix) })
}

@Test
func passesTheFixturesOwnExpectedAndTranscriptToTheScorer() async throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    nonisolated(unsafe) var arguments: [String] = []
    let summary = makeSummary(actionItems: [groundedItem("Ship it", of: widgetTranscript, utterance: 0)], costUSD: 0.01)

    _ = await RecallBenchRunner.run(
        fixtures: [benchFixture(directory: root.url)],
        arms: [StrategyComparisonArm(label: "substring", strategy: StubSummarizer(result: .success(summary)))],
        scorer: stubScorer { _, captured in arguments = captured },
        workingDirectory: root.url.appendingPathComponent("work", isDirectory: true),
    )

    #expect(arguments.first == "note")
    #expect(Array(arguments.suffix(2)) == [
        root.url.appendingPathComponent("expected.json").path,
        root.url.appendingPathComponent("transcript.json").path,
    ])
}

@Test
func anArmThatThrowsRecordsAReasonWhileTheOtherArmStillScores() async throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    let summary = makeSummary(actionItems: [groundedItem("Ship it", of: widgetTranscript, utterance: 0)], costUSD: 0.01)
    let arms = [
        StrategyComparisonArm(label: "citations", strategy: StubSummarizer(result: .failure(.refused))),
        StrategyComparisonArm(label: "substring", strategy: StubSummarizer(result: .success(summary))),
    ]

    let result = await RecallBenchRunner.run(
        fixtures: [benchFixture(directory: root.url)],
        arms: arms,
        scorer: stubScorer(),
        workingDirectory: root.url.appendingPathComponent("work", isDirectory: true),
    )

    #expect(result.rows.count == 2)
    #expect(result.rows[0].failureReason != nil)
    #expect(result.rows[0].score == nil)
    #expect(result.rows[0].costUSD == 0)
    #expect(result.rows[1].score == passingScore)
}

@Test
func aScorerFailureBecomesTheRowsReasonAndTheRunContinues() async throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    let summary = makeSummary(actionItems: [groundedItem("Ship it", of: widgetTranscript, utterance: 0)], costUSD: 0.02)
    let refusing = RecallBenchScorer(scriptURL: URL(fileURLWithPath: "/nowhere/score.py")) { _, _ in
        throw RecallBenchScorer.ScoreError.scorerFailed(status: 2, stderr: "boom")
    }

    let result = await RecallBenchRunner.run(
        fixtures: [benchFixture(id: "A", directory: root.url), benchFixture(id: "B", directory: root.url)],
        arms: [StrategyComparisonArm(label: "substring", strategy: StubSummarizer(result: .success(summary)))],
        scorer: refusing,
        workingDirectory: root.url.appendingPathComponent("work", isDirectory: true),
    )

    #expect(result.rows.count == 2)
    #expect(result.rows.allSatisfy { $0.score == nil })
    #expect(result.rows.allSatisfy { $0.failureReason?.contains("boom") == true })
    // The call was already paid for, so a scoring failure still reports cost.
    #expect(result.rows.allSatisfy { $0.costUSD == 0.02 })
}
