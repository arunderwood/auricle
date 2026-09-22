import RecallBench
import Testing

/// The section split defaults to everything under Action Items, so a case
/// that does not care which section an item landed in still describes a
/// coherent note: the totals are the sum of the two sections, as `score.py`
/// computes them. A case that does care passes `dec` explicitly.
private func score(
    kept: Int,
    recalled: Int,
    expected: Int,
    falseKeeps: Int,
    ungrounded: Int = 0,
    dec: RecallBenchSectionScore = RecallBenchSectionScore(kept: 0, expected: 0, recalled: 0, falseKeeps: 0),
) -> RecallBenchScore {
    RecallBenchScore(
        keptItems: kept + dec.kept,
        ungroundedQuotes: ungrounded,
        expectedItems: expected + dec.expected,
        recalledItems: recalled + dec.recalled,
        falseKeeps: falseKeeps + dec.falseKeeps,
        actionItems: RecallBenchSectionScore(kept: kept, expected: expected, recalled: recalled, falseKeeps: falseKeeps),
        decisions: dec,
    )
}

@Test
func printsOneLinePerMeetingOneTotalPerArmAndOneElapsedFooter() {
    let rows = [
        RecallBenchRow(
            arm: "substring:recall-v2",
            meeting: "ES2002a",
            score: score(
                kept: 3,
                recalled: 3,
                expected: 3,
                falseKeeps: 0,
                dec: RecallBenchSectionScore(kept: 1, expected: 0, recalled: 0, falseKeeps: 1),
            ),
            costUSD: 0.055,
            failureReason: nil,
        ),
        RecallBenchRow(
            arm: "substring:recall-v2",
            meeting: "ES2002b",
            // The real ES2002b shape: every decision found, no action item
            // produced at all, from the same closing passage. The totals
            // alone read as a middling 4/8 and hide it entirely.
            score: score(
                kept: 0,
                recalled: 0,
                expected: 4,
                falseKeeps: 0,
                ungrounded: 1,
                dec: RecallBenchSectionScore(kept: 4, expected: 4, recalled: 4, falseKeeps: 0),
            ),
            costUSD: 0.0977,
            failureReason: nil,
        ),
    ]

    let report = RecallBenchReportRenderer.render(rows: rows, elapsed: .seconds(41))

    #expect(report == """
    arm                     meeting     kept  false  ungnd      act      dec   recall       cost
    substring:recall-v2     ES2002a        4      1      0      3/3      0/0      3/3   $ 0.0550
    substring:recall-v2     ES2002b        4      0      1      0/4      4/4      4/8   $ 0.0977
    substring:recall-v2  item recall 7/11 = 64% (act 3/7, dec 4/4), false keeps 1 (act 0, dec 1), ungrounded 1, $ 0.1527
    elapsed 41s

    """)
}

@Test
func keepsEachArmsTotalsSeparateAndTimesTheRunOnce() {
    let rows = [
        RecallBenchRow(arm: "citations", meeting: "ES2002a", score: score(kept: 2, recalled: 1, expected: 3, falseKeeps: 1), costUSD: 0.02, failureReason: nil),
        RecallBenchRow(arm: "substring", meeting: "ES2002a", score: score(kept: 3, recalled: 3, expected: 3, falseKeeps: 0), costUSD: 0.03, failureReason: nil),
    ]

    let lines = RecallBenchReportRenderer.render(rows: rows, elapsed: .seconds(10)).split(separator: "\n")

    #expect(lines.contains("citations  item recall 1/3 = 33% (act 1/3, dec 0/0), false keeps 1 (act 1, dec 0), ungrounded 0, $ 0.0200"))
    #expect(lines.contains("substring  item recall 3/3 = 100% (act 3/3, dec 0/0), false keeps 0 (act 0, dec 0), ungrounded 0, $ 0.0300"))
    #expect(lines.count { $0.hasPrefix("elapsed ") } == 1)
    #expect(lines.last == "elapsed 10s")
}

@Test
func aFailedArmPrintsItsCostAndReasonAndIsCountedInTheTotal() {
    let rows = [
        RecallBenchRow(arm: "citations", meeting: "ES2002a", score: score(kept: 2, recalled: 2, expected: 3, falseKeeps: 0), costUSD: 0.02, failureReason: nil),
        RecallBenchRow(arm: "citations", meeting: "ES2002b", score: nil, costUSD: 0.03, failureReason: "score.py exited 2: boom"),
    ]

    let report = RecallBenchReportRenderer.render(rows: rows, elapsed: .seconds(5))

    // The scoring failed after the call was paid for, so the arm total's
    // $0.0500 has to reconcile against the two per-meeting lines.
    #expect(report.contains("   $ 0.0300  FAILED: score.py exited 2: boom"))
    #expect(report.contains("citations  item recall 2/3 = 67% (act 2/3, dec 0/0), false keeps 0 (act 0, dec 0), ungrounded 0, $ 0.0500, 1 failed"))
}

@Test
func aMultiLineFailureReasonStaysOnOneBoundedLine() {
    let traceback = "score.py exited 1: Traceback (most recent call last):\n  File \"score.py\", line 1\n"
        + String(repeating: "KeyError: 'action_items' ", count: 20)
    let rows = [RecallBenchRow(arm: "citations", meeting: "ES2002a", score: nil, costUSD: 0, failureReason: traceback)]

    let report = RecallBenchReportRenderer.render(rows: rows, elapsed: .seconds(1))
    let lines = report.split(separator: "\n")

    // Header, the one row, the arm total, the elapsed footer — the traceback
    // adds no lines of its own.
    #expect(lines.count == 4)
    #expect(lines.allSatisfy { $0.count <= 200 })
    #expect(report.contains("FAILED: score.py exited 1: Traceback (most recent call last):   File \"score.py\", line 1 KeyError:"))
    #expect(report.contains("…"))
}

@Test
func anArmWhoseRowsAllFailedReportsNoRecallRatherThanDividingByZero() {
    let rows = [
        RecallBenchRow(arm: "citations", meeting: "ES2002a", score: nil, costUSD: 0, failureReason: "SummarizerError.apiKeyMissing"),
    ]

    let report = RecallBenchReportRenderer.render(rows: rows, elapsed: .seconds(1))

    #expect(report.contains("citations  item recall 0/0 = 0% (act 0/0, dec 0/0), false keeps 0 (act 0, dec 0), ungrounded 0, $ 0.0000, 1 failed"))
}
