import Core
import Foundation
@testable import Summarize
import SummarizerInterface
import Testing

// MARK: - Fixtures

private let transcriptText = "Ada: ship it 🚀 by Friday.\nBen: I'll draft the café brief."

/// UTF-8 byte range of `needle` in `transcriptText` — the convention every
/// `GroundingPointer` uses, which differs from a `String` character range
/// as soon as the text has an emoji or an accent.
private func byteRange(of needle: String) -> (start: Int, end: Int) {
    guard let range = transcriptText.range(of: needle) else {
        Issue.record("needle not found in transcript text")
        return (0, 0)
    }
    let start = transcriptText.utf8.distance(from: transcriptText.startIndex, to: range.lowerBound)
    return (start, start + needle.utf8.count)
}

private func pointer(_ start: Int, _ end: Int) -> GroundingPointer {
    GroundingPointer(transcriptStart: start, transcriptEnd: end, sourceMethod: .substring)
}

private func makeRows() -> [SmokeTestRow] {
    let draft = byteRange(of: "I'll draft the café brief.")
    let both = byteRange(of: "ship it 🚀 by Friday.\nBen: I'll")
    let summary = SummaryWithGrounding(
        schemaVersion: 1,
        summary: "SECRET-SUMMARY",
        actionItems: [GroundedItem(text: "SECRET-ITEM-TEXT Ben drafts the brief", grounding: pointer(draft.start, draft.end))],
        decisions: [GroundedItem(text: "SECRET-DECISION-TEXT", grounding: pointer(both.start, both.end))],
        groundingMethod: .substring,
        cost: SummarizerCost(inputTokens: 1200, outputTokens: 300, thinkingTokens: 45, costUSD: 0.1234),
        quoteValidationDropCount: 2,
    )
    let transcript = CanonicalTranscript(text: transcriptText, utterances: [])
    return [
        SmokeTestRow(name: "standup", transcript: transcript, arms: [
            SmokeTestArmResult(label: "citations", outcome: .failure(reason: "SummarizerError.citationsUnavailable")),
            SmokeTestArmResult(label: "substring", outcome: .summary(summary)),
        ]),
    ]
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func metricsReport() -> String {
    SmokeTestReportRenderer.metricsReport(rows: makeRows(), generatedAt: now, modelIdentifier: "claude-opus-5")
}

private func detailReport(rows: [SmokeTestRow] = makeRows()) -> String {
    SmokeTestReportRenderer.detailReport(rows: rows, generatedAt: now, modelIdentifier: "claude-opus-5")
}

// MARK: - Tests

struct SmokeTestReportTests {
    @Test func metricsReportHasNoItemTextOrSourceQuote() {
        let report = metricsReport()

        #expect(!report.contains("SECRET"))
        #expect(!report.contains("draft the café"))
        #expect(!report.contains("ship it"))
        // The default-flip rule is the one blockquote the metrics report may hold.
        let blockquoteLines = report.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix(">")
        }
        #expect(blockquoteLines == SmokeTestReportRenderer.flipRuleLines.map { "> \($0)" })
    }

    @Test func metricsReportRecordsComputedMetricsPerArmInOrder() {
        let report = metricsReport()

        #expect(report.contains("| standup | citations | failed: SummarizerError.citationsUnavailable | - |"))
        #expect(report.contains("| standup | substring | ok | substring | 1 | 1 | 2 | 0.1234 | 1200 | 300 | 45 |"))
        let citationsRow = report.range(of: "| standup | citations | failed")
        let substringRow = report.range(of: "| standup | substring | ok")
        #expect(citationsRow != nil && substringRow != nil)
        if let citationsRow, let substringRow {
            #expect(citationsRow.lowerBound < substringRow.lowerBound)
        }
    }

    @Test func bothReportsCarryBlankHumanScoreCellsAndTheFlipRuleVerbatim() {
        for report in [metricsReport(), detailReport()] {
            #expect(report.contains("| Transcript | Arm | Recall | Precision (false-keeps) | Quote quality |"))
            #expect(report.contains("| standup | citations |  |  |  |"))
            #expect(report.contains("| standup | substring |  |  |  |"))
            #expect(report.contains("## Default and rationale"))
            #expect(report.contains("Default: \n"))
            #expect(report.contains("Rationale: \n"))
            for line in SmokeTestReportRenderer.flipRuleLines {
                #expect(report.contains("> \(line)"))
            }
        }
    }

    @Test func flipRuleStatesBothHalvesOfStory38() {
        let rule = SmokeTestReportRenderer.flipRuleLines.joined(separator: "\n")

        #expect(rule.contains("Citations is locked as MVP default IF Citations matches or beats substring on every transcript"))
        #expect(rule.contains("the default flips to substring IF substring catches anything Citations missed (any false-drop, any recall miss)"))
        #expect(rule.contains("cost of one missed commitment in dogfood >> cost of running with a slightly-less-capable validator"))
    }

    @Test func detailReportFollowsEachItemWithItsQuoteSlicedByUTF8Range() {
        let report = detailReport()

        #expect(report.contains("1. SECRET-ITEM-TEXT Ben drafts the brief\n\n   > I'll draft the café brief."))
        // A quote spanning a line break keeps every line inside the blockquote.
        #expect(report.contains("   > ship it 🚀 by Friday.\n   > Ben: I'll"))
        #expect(report.contains("Failed: SummarizerError.citationsUnavailable"))
    }

    @Test func detailReportRendersAPlaceholderForAnUnusableRangeInsteadOfTrapping() {
        let emoji = byteRange(of: "🚀")
        let pointers: [(GroundingPointer, String)] = [
            (pointer(0, 10000), SmokeTestReportRenderer.outOfRangePlaceholder),
            (pointer(-1, 4), SmokeTestReportRenderer.outOfRangePlaceholder),
            (pointer(9, 4), SmokeTestReportRenderer.outOfRangePlaceholder),
            (pointer(emoji.start + 1, emoji.end), SmokeTestReportRenderer.notOnBoundaryPlaceholder),
            (pointer(emoji.start, emoji.end - 1), SmokeTestReportRenderer.notOnBoundaryPlaceholder),
        ]
        let transcript = CanonicalTranscript(text: transcriptText, utterances: [])

        for (badPointer, placeholder) in pointers {
            let summary = SummaryWithGrounding(
                schemaVersion: 1,
                summary: "s",
                actionItems: [GroundedItem(text: "item", grounding: badPointer)],
                decisions: [],
                groundingMethod: .substring,
                cost: SummarizerCost(inputTokens: 0, outputTokens: 0, thinkingTokens: 0, costUSD: 0),
                quoteValidationDropCount: 0,
            )
            let row = SmokeTestRow(name: "t", transcript: transcript, arms: [
                SmokeTestArmResult(label: "arm", outcome: .summary(summary)),
            ])

            #expect(detailReport(rows: [row]).contains("   > \(placeholder)"))
        }
    }

    @Test func tableCellsEscapePipesAndLineBreaks() {
        let transcript = CanonicalTranscript(text: "", utterances: [])
        let row = SmokeTestRow(name: "a|b\nc", transcript: transcript, arms: [
            SmokeTestArmResult(label: "x|y", outcome: .failure(reason: "r")),
        ])

        let report = SmokeTestReportRenderer.metricsReport(rows: [row], generatedAt: now, modelIdentifier: "m")

        #expect(report.contains("| a\\|b c | x\\|y | failed: r |"))
    }

    @Test func writerCreatesTheOutputDirectoryAndBothReports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("smoke-test-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("nested/out")

        let paths = try SmokeTestReportWriter.write(rows: makeRows(), generatedAt: now, modelIdentifier: "claude-opus-5", to: output)

        #expect(paths.metrics.lastPathComponent == "results.md")
        #expect(paths.detail.lastPathComponent == "detail.md")
        #expect(try String(contentsOf: paths.metrics, encoding: .utf8) == metricsReport())
        #expect(try String(contentsOf: paths.detail, encoding: .utf8) == detailReport())
        let contents = try FileManager.default.contentsOfDirectory(atPath: output.path).sorted()
        #expect(contents == ["detail.md", "results.md"])
    }
}
