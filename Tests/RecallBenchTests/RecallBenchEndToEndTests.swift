import Core
import Foundation
import RecallBench
import Summarize
import SummarizerInterface
import Testing

/// The seam the whole bench rests on, with nothing stubbed but the paid call:
/// a committed reference fixture, its own grounding pointers, the shipped
/// artifact mapper and frontmatter renderer, and the real `score.py`. A
/// renderer that emits a shape the scorer's parser does not read — or a quote
/// that does not survive the blockquote round trip — fails here and nowhere
/// else.
@Test(.enabled(if: python3IsAvailable, "needs python3 on PATH"))
func everyExpectedItemOfARealFixtureSurvivesTheShippedRendererAndTheRealScorer() async throws {
    let fixture = try #require(try RecallBenchFixtureLoader.load(repoRoot: repoRoot).first { $0.id == "ES2002b" })
    let expected = try ExpectedItems.read(from: fixture.directory)
    let root = try TemporaryRoot()
    defer { root.cleanUp() }

    let summary = makeSummary(
        actionItems: expected.actionItems.map(\.grounded) + [spanningItem(of: fixture.transcript)],
        decisions: expected.decisions.map(\.grounded),
        costUSD: 0.05,
    )

    let result = await RecallBenchRunner.run(
        fixtures: [fixture],
        arms: [StrategyComparisonArm(label: "substring", strategy: StubSummarizer(result: .success(summary)))],
        scorer: RecallBenchScorer(scriptURL: scoreScriptURL),
        workingDirectory: root.url,
    )

    let row = try #require(result.rows.first)
    let score = try #require(row.score, "the bench recorded a failure: \(row.failureReason ?? "none")")
    #expect(score.expectedItems == expected.actionItems.count + expected.decisions.count)
    #expect(score.recalledItems == score.expectedItems)
    // Offline there is no separate hypothesis, so every kept quote — the
    // multi-line one included — has to be a verbatim slice of this transcript.
    #expect(score.ungroundedQuotes == 0)
}

/// An item whose grounding crosses an utterance boundary, so the note carries
/// a multi-line blockquote: the one note shape the fixtures' own single-line
/// quotes never produce.
private func spanningItem(of transcript: CanonicalTranscript) -> GroundedItem {
    GroundedItem(
        text: "A passage spanning several utterances",
        grounding: GroundingPointer(
            transcriptStart: transcript.utterances[5].start,
            transcriptEnd: transcript.utterances[7].end,
            sourceMethod: .substring,
        ),
    )
}
