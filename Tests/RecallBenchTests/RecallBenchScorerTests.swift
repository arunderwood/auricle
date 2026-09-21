import Foundation
import RecallBench
import Testing

private let scriptURL = URL(fileURLWithPath: "/nowhere/score.py")

@Test
func decodesTheScorersSnakeCaseObject() throws {
    let stdout = #"{"kept_items":4,"ungrounded_quotes":0,"expected_items":3,"recalled_items":2,"false_keeps":1}"#
    let scorer = RecallBenchScorer(scriptURL: scriptURL) { _, _ in Data(stdout.utf8) }

    let score = try scorer.score(notePath: scriptURL, expectedPath: scriptURL, transcriptPath: scriptURL)

    #expect(score == RecallBenchScore(keptItems: 4, ungroundedQuotes: 0, expectedItems: 3, recalledItems: 2, falseKeeps: 1))
}

@Test
func passesTheNoteSubcommandAndItsThreePositionalPaths() throws {
    nonisolated(unsafe) var seen: (url: URL, arguments: [String])?
    let scorer = RecallBenchScorer(scriptURL: scriptURL) { url, arguments in
        seen = (url, arguments)
        return Data(#"{"kept_items":0,"ungrounded_quotes":0,"expected_items":0,"recalled_items":0,"false_keeps":0}"#.utf8)
    }

    _ = try scorer.score(
        notePath: URL(fileURLWithPath: "/tmp/note.md"),
        expectedPath: URL(fileURLWithPath: "/tmp/expected.json"),
        transcriptPath: URL(fileURLWithPath: "/tmp/transcript.json"),
    )

    let call = try #require(seen)
    #expect(call.url == scriptURL)
    #expect(call.arguments == ["note", "/tmp/note.md", "/tmp/expected.json", "/tmp/transcript.json"])
}

@Test
func aNonZeroExitReachesTheCaller() throws {
    let failure = RecallBenchScorer.ScoreError.scorerFailed(status: 2, stderr: "Traceback")
    let scorer = RecallBenchScorer(scriptURL: scriptURL) { _, _ in throw failure }

    #expect(throws: failure) {
        try scorer.score(notePath: scriptURL, expectedPath: scriptURL, transcriptPath: scriptURL)
    }
}

@Test
func outputThatIsNotAScoreObjectIsUndecodable() throws {
    let scorer = RecallBenchScorer(scriptURL: scriptURL) { _, _ in Data("not json".utf8) }

    #expect(throws: RecallBenchScorer.ScoreError.scoreUndecodable) {
        try scorer.score(notePath: scriptURL, expectedPath: scriptURL, transcriptPath: scriptURL)
    }
}

/// The Python side of the contract: the real `score.py note` invoked through
/// the real runner, so a change to either side's field names fails here.
/// Skipped where `python3` is not on `PATH`, which reports the contract as
/// unverified rather than met.
@Test(.enabled(if: python3IsAvailable, "needs python3 on PATH"))
func theRealScorerScoresARenderedNote() async throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    let quote = "we will ship the widget on Friday without fail"
    try root.writeFixtureFile(
        "transcript.json",
        contents: #"{"text": "Speaker_1: \#(quote) and nothing else happened"}"#,
    )
    try root.writeFixtureFile(
        "expected.json",
        contents: #"{"action_items": [{"text": "Ship the widget", "quote": "\#(quote)"}], "decisions": []}"#,
    )
    try root.writeFixtureFile(
        "note.md",
        contents: "## Action Items\n\n- Ship the widget\n  > \(quote)\n\n## Decisions\n",
    )

    let scorer = RecallBenchScorer(scriptURL: scoreScriptURL)
    let score = try await scorer.score(
        notePath: root.url.appendingPathComponent("note.md"),
        expectedPath: root.url.appendingPathComponent("expected.json"),
        transcriptPath: root.url.appendingPathComponent("transcript.json"),
    )

    #expect(score == RecallBenchScore(keptItems: 1, ungroundedQuotes: 0, expectedItems: 1, recalledItems: 1, falseKeeps: 0))
}

/// `false_keeps` counts a kept bullet that no expected item under its OWN
/// heading matches. Both bullets here are false keeps: the first matches
/// nothing at all, and the second quotes the expected Action Item passage
/// under Decisions, where no expected item lives. Dropping `score_note`'s
/// same-heading filter would score this 1.
@Test(.enabled(if: python3IsAvailable, "needs python3 on PATH"))
func theRealScorerCountsACrossHeadingKeepAsAFalseKeep() async throws {
    let root = try TemporaryRoot()
    defer { root.cleanUp() }
    let wanted = "we will ship the widget on Friday without fail"
    let unrelated = "the coffee machine broke again this morning"
    try root.writeFixtureFile(
        "transcript.json",
        contents: #"{"text": "Speaker_1: \#(wanted)\nSpeaker_2: \#(unrelated)"}"#,
    )
    try root.writeFixtureFile(
        "expected.json",
        contents: #"{"action_items": [{"text": "Ship the widget", "quote": "\#(wanted)"}], "decisions": []}"#,
    )
    try root.writeFixtureFile(
        "note.md",
        contents: """
        ## Action Items

        - Fix the coffee machine
          > \(unrelated)

        ## Decisions

        - Ship the widget
          > \(wanted)

        """,
    )

    let scorer = RecallBenchScorer(scriptURL: scoreScriptURL)
    let score = try await scorer.score(
        notePath: root.url.appendingPathComponent("note.md"),
        expectedPath: root.url.appendingPathComponent("expected.json"),
        transcriptPath: root.url.appendingPathComponent("transcript.json"),
    )

    #expect(score.falseKeeps == 2)
    #expect(score.keptItems == 2)
    #expect(score.recalledItems == 0)
    #expect(score.ungroundedQuotes == 0)
}
