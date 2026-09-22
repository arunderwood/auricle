import Foundation

/// The bench's whole output: one line per arm per meeting, one total line per
/// arm, then the run's wall clock. The shape mirrors `score.py report`, so a
/// bench run and a regression run read the same way.
///
///     arm                     meeting     kept  false  ungnd      act      dec   recall       cost
///     substring:recall-v2     ES2002a        4      1      0      3/3      0/0      3/3   $ 0.0550
///     substring:recall-v2  item recall 7/11 = 64% (act 4/8, dec 3/3), false keeps 3 (act 1, dec 2), ungrounded 0, $ 0.1527
///     elapsed 41s
public enum RecallBenchReportRenderer {
    private static let meetingWidth = 7
    private static let keptWidth = 9
    private static let falseWidth = 7
    private static let ungroundedWidth = 7
    private static let sectionWidth = 9
    private static let recallWidth = 9
    private static let costWidth = 11

    /// A `score.py` traceback reaches the failure line as its whole stderr.
    /// Left alone it would inject newlines and hundreds of columns into a
    /// fixed-width table that a reader — or an `awk` one-liner — parses by
    /// line and column.
    private static let maxReasonLength = 120

    public static func render(rows: [RecallBenchRow], elapsed: Duration) -> String {
        // The arm column holds the longest label plus a two-space gutter, and
        // never narrows below the header's own width.
        let armWidth = max(24, (rows.map(\.arm.count).max() ?? 0) + 2)
        var lines = [header(armWidth: armWidth)]
        lines += rows.map { line(for: $0, armWidth: armWidth) }
        lines += totals(rows: rows)
        lines.append("elapsed \(seconds(elapsed))s")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func header(armWidth: Int) -> String {
        pad("arm", armWidth)
            + pad("meeting", meetingWidth)
            + padLeft("kept", keptWidth)
            + padLeft("false", falseWidth)
            + padLeft("ungnd", ungroundedWidth)
            + padLeft("act", sectionWidth)
            + padLeft("dec", sectionWidth)
            + padLeft("recall", recallWidth)
            + padLeft("cost", costWidth)
    }

    private static func line(for row: RecallBenchRow, armWidth: Int) -> String {
        let prefix = pad(row.arm, armWidth) + pad(row.meeting, meetingWidth)
        guard let score = row.score else {
            // The cost is printed even here: an arm that summarized and then
            // failed to score was already paid for, and the arm total sums it.
            return prefix + padLeft(cost(row.costUSD), costWidth) + "  FAILED: \(reason(row.failureReason))"
        }
        return prefix
            + padLeft(String(score.keptItems), keptWidth)
            + padLeft(String(score.falseKeeps), falseWidth)
            + padLeft(String(score.ungroundedQuotes), ungroundedWidth)
            + padLeft("\(score.actionItems.recalled)/\(score.actionItems.expected)", sectionWidth)
            + padLeft("\(score.decisions.recalled)/\(score.decisions.expected)", sectionWidth)
            + padLeft("\(score.recalledItems)/\(score.expectedItems)", recallWidth)
            + padLeft(cost(row.costUSD), costWidth)
    }

    private static func reason(_ raw: String?) -> String {
        let collapsed = (raw ?? "unknown")
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
        guard collapsed.count > maxReasonLength else { return collapsed }
        return collapsed.prefix(maxReasonLength) + "…"
    }

    /// One line per arm, in the order the arms first appear, carrying the
    /// numbers the story is gated on: item recall over the whole set, the
    /// false keeps that recall was bought with, the ungrounded quotes
    /// `score.py report` gates at zero, and cost. Elapsed is not here — it is
    /// one wall clock for the whole run, not a figure per arm.
    private static func totals(rows: [RecallBenchRow]) -> [String] {
        var seen: [String] = []
        for row in rows where !seen.contains(row.arm) {
            seen.append(row.arm)
        }
        return seen.map { arm in
            let armRows = rows.filter { $0.arm == arm }
            let recalled = armRows.reduce(0) { $0 + ($1.score?.recalledItems ?? 0) }
            let expected = armRows.reduce(0) { $0 + ($1.score?.expectedItems ?? 0) }
            let falseKeeps = armRows.reduce(0) { $0 + ($1.score?.falseKeeps ?? 0) }
            let ungrounded = armRows.reduce(0) { $0 + ($1.score?.ungroundedQuotes ?? 0) }
            let totalCost = armRows.reduce(0.0) { $0 + $1.costUSD }
            let percent = expected == 0 ? 0 : Int((Double(recalled) / Double(expected) * 100).rounded())
            let failed = armRows.count { $0.failureReason != nil }
            let failures = failed == 0 ? "" : ", \(failed) failed"
            let actRecalled = armRows.reduce(0) { $0 + ($1.score?.actionItems.recalled ?? 0) }
            let actExpected = armRows.reduce(0) { $0 + ($1.score?.actionItems.expected ?? 0) }
            let decRecalled = armRows.reduce(0) { $0 + ($1.score?.decisions.recalled ?? 0) }
            let decExpected = armRows.reduce(0) { $0 + ($1.score?.decisions.expected ?? 0) }
            let actFalse = armRows.reduce(0) { $0 + ($1.score?.actionItems.falseKeeps ?? 0) }
            let decFalse = armRows.reduce(0) { $0 + ($1.score?.decisions.falseKeeps ?? 0) }
            return "\(arm)  item recall \(recalled)/\(expected) = \(percent)% "
                + "(act \(actRecalled)/\(actExpected), dec \(decRecalled)/\(decExpected)), "
                + "false keeps \(falseKeeps) (act \(actFalse), dec \(decFalse)), "
                + "ungrounded \(ungrounded), \(cost(totalCost))\(failures)"
        }
    }

    private static func cost(_ usd: Double) -> String {
        "$ " + String(format: "%.4f", usd)
    }

    private static func seconds(_ elapsed: Duration) -> Int {
        Int(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    }

    private static func pad(_ value: String, _ width: Int) -> String {
        value + String(repeating: " ", count: max(0, width - value.count))
    }

    private static func padLeft(_ value: String, _ width: Int) -> String {
        String(repeating: " ", count: max(0, width - value.count)) + value
    }
}
