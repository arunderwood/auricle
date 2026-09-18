import Core
import Foundation
import SummarizerInterface

/// Renders smoke-test rows as Markdown in two modes. `metricsReport` holds
/// only counts, costs and failure reasons — no item text and no source
/// quote — but it prints fixture file names as given, so fixtures must be
/// named neutrally before it is committed. `detailReport` adds each kept item
/// and its source quote, which is real meeting content, so it is never
/// committed.
///
/// Both carry blank cells for the metrics only the maintainer can judge
/// (recall, precision, quote quality) and a blank default/rationale section.
/// The renderer does not compute a recommended default: recall and
/// false-drop are human judgments, so a computed verdict would be false
/// precision.
public enum SmokeTestReportRenderer {
    /// The default-flip rule, verbatim from Story 3.8's acceptance criteria
    /// (epics.md), in the two halves the story states it in.
    static let flipRuleLines = [
        "Citations is locked as MVP default IF Citations matches or beats substring on every transcript",
        "the default flips to substring IF substring catches anything Citations missed (any false-drop, any recall miss) on any "
            + "transcript in the smoke-test set (trust-asymmetry: cost of one missed commitment in dogfood >> cost of running with "
            + "a slightly-less-capable validator that doesn't drop real items)",
    ]

    static let outOfRangePlaceholder = "[source range is outside the transcript]"
    static let notOnBoundaryPlaceholder = "[source range does not fall on a character boundary]"

    public static func metricsReport(rows: [SmokeTestRow], generatedAt: Date, modelIdentifier: String) -> String {
        render(
            title: "Decision 3.6 smoke-test results",
            note: "Metrics only: no item text and no source quotes. Fixture file names appear as given, so name fixtures neutrally before committing.",
            rows: rows,
            generatedAt: generatedAt,
            modelIdentifier: modelIdentifier,
            includeItems: false,
        )
    }

    public static func detailReport(rows: [SmokeTestRow], generatedAt: Date, modelIdentifier: String) -> String {
        render(
            title: "Decision 3.6 smoke-test detail",
            note: "Contains real meeting content (kept items and source quotes). Never commit this file.",
            rows: rows,
            generatedAt: generatedAt,
            modelIdentifier: modelIdentifier,
            includeItems: true,
        )
    }

    // MARK: - Sections

    private static func render(
        title: String,
        note: String,
        rows: [SmokeTestRow],
        generatedAt: Date,
        modelIdentifier: String,
        includeItems: Bool,
    ) -> String {
        var lines = [
            "# \(title)",
            "",
            note,
            "",
            "- Generated: \(ISO8601UTC.string(from: generatedAt))",
            "- Model: \(cell(modelIdentifier))",
            "- Transcripts: \(rows.count)",
            "",
        ]
        lines += computedMetricsSection(rows: rows)
        if includeItems {
            lines += itemsSection(rows: rows)
        }
        lines += humanScoredSection(rows: rows)
        lines += defaultSection()
        return lines.joined(separator: "\n") + "\n"
    }

    private static func computedMetricsSection(rows: [SmokeTestRow]) -> [String] {
        var lines = [
            "## Computed metrics",
            "",
            "| Transcript | Arm | Status | Grounding method | Action items kept | Decisions kept "
                + "| quote_validation_drop_count | Cost (USD) | Input tokens | Output tokens | Thinking tokens |",
            "|---|---|---|---|---|---|---|---|---|---|---|",
        ]
        for row in rows {
            for arm in row.arms {
                lines.append(metricsRow(transcriptName: row.name, arm: arm))
            }
        }
        lines.append("")
        return lines
    }

    private static func metricsRow(transcriptName: String, arm: SmokeTestArmResult) -> String {
        let leading = "| \(cell(transcriptName)) | \(cell(arm.label))"
        switch arm.outcome {
        case let .summary(summary):
            let cost = summary.cost
            let cells = [
                "ok",
                summary.groundingMethod.rawValue,
                "\(summary.actionItems.count)",
                "\(summary.decisions.count)",
                "\(summary.quoteValidationDropCount)",
                String(format: "%.4f", cost.costUSD),
                "\(cost.inputTokens)",
                "\(cost.outputTokens)",
                "\(cost.thinkingTokens)",
            ]
            return leading + " | " + cells.joined(separator: " | ") + " |"
        case let .failure(reason):
            let cells = ["failed: \(cell(reason))"] + Array(repeating: "-", count: 8)
            return leading + " | " + cells.joined(separator: " | ") + " |"
        }
    }

    private static func itemsSection(rows: [SmokeTestRow]) -> [String] {
        var lines = ["## Kept items", ""]
        for row in rows {
            lines += ["### \(inline(row.name))", ""]
            let bytes = Array(row.transcript.text.utf8)
            for arm in row.arms {
                lines += ["#### \(inline(arm.label))", ""]
                switch arm.outcome {
                case let .summary(summary):
                    lines += itemList(title: "Action items", items: summary.actionItems, transcriptBytes: bytes)
                    lines += itemList(title: "Decisions", items: summary.decisions, transcriptBytes: bytes)
                case let .failure(reason):
                    lines += ["Failed: \(inline(reason))", ""]
                }
            }
        }
        return lines
    }

    private static func itemList(title: String, items: [GroundedItem], transcriptBytes: [UInt8]) -> [String] {
        var lines = ["**\(title)**", ""]
        if items.isEmpty {
            lines += ["_none kept_", ""]
            return lines
        }
        for (index, item) in items.enumerated() {
            lines.append("\(index + 1). \(inline(item.text))")
            lines.append("")
            for quoteLine in sourceQuote(for: item.grounding, in: transcriptBytes).components(separatedBy: "\n") {
                lines.append("   > \(quoteLine)")
            }
            lines.append("")
        }
        return lines
    }

    private static func humanScoredSection(rows: [SmokeTestRow]) -> [String] {
        var lines = [
            "## Human-scored metrics",
            "",
            "Fill in by hand. These are judgments the rig cannot compute.",
            "",
            "- Recall: items present in your memory of the meeting that survived to rendered output.",
            "- Precision (false-keeps): items the validator accepted that are not real commitments.",
            "- Quote quality: did the grounded quote read sensibly rendered as `> source quote`?",
            "",
            "| Transcript | Arm | Recall | Precision (false-keeps) | Quote quality |",
            "|---|---|---|---|---|",
        ]
        for row in rows {
            for arm in row.arms {
                lines.append("| \(cell(row.name)) | \(cell(arm.label)) |  |  |  |")
            }
        }
        lines.append("")
        return lines
    }

    private static func defaultSection() -> [String] {
        var lines = [
            "## Default and rationale",
            "",
            "Default-flip rule (Story 3.8, Decision 3.6):",
            "",
        ]
        lines += flipRuleLines.map { "> \($0)" }
        lines += [
            "",
            "Default: ",
            "",
            "Rationale: ",
            "",
        ]
        return lines
    }

    // MARK: - Source quotes

    /// The transcript text a pointer names, sliced by UTF-8 byte range —
    /// the same convention every `GroundingPointer` uses. A range that is
    /// out of bounds, inverted, or lands inside a multi-byte scalar renders
    /// a placeholder: a bad pointer must not trap the report.
    static func sourceQuote(for pointer: GroundingPointer, in transcriptBytes: [UInt8]) -> String {
        switch TranscriptSlicer.slice(pointer, of: transcriptBytes) {
        case let .success(quote): quote
        case .failure(.outOfRange): outOfRangePlaceholder
        case .failure(.notOnScalarBoundary): notOnBoundaryPlaceholder
        }
    }

    // MARK: - Escaping

    /// Table cells are single-line and `|`-delimited.
    private static func cell(_ text: String) -> String {
        inline(text).replacingOccurrences(of: "|", with: "\\|")
    }

    /// Collapses line breaks so text stays on the Markdown line it was placed on.
    private static func inline(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
