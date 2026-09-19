import Core
import Foundation
import SummarizerInterface

/// The outcome of scoring one run against a fixture: the counts behind the
/// summary line, and one message per threshold or check that failed.
struct EvalScore: Equatable {
    let fixtureName: String
    let groundingMethod: GroundingMethod
    let keptCount: Int
    let expectedCount: Int
    let survivedCount: Int
    /// The summary's own `quoteValidationDropCount`, decoy drops included.
    let reportedDrops: Int
    let falseKeeps: Int
    let failures: [String]

    var passed: Bool {
        failures.isEmpty
    }

    var summaryLine: String {
        "Fixture \(fixtureName): kept \(keptCount) items (\(expectedCount) expected)"
            + " · dropped \(reportedDrops) · false-keeps \(falseKeeps) · grounding_method=\(groundingMethod.rawValue)"
    }
}

/// Scores one summarizer run against a fixture's `expected.json`. A pure
/// function of its inputs: no I/O, no clock, and nothing from the pipeline
/// under test beyond the values it is handed.
enum EvalScorer {
    /// Tolerance for comparing a ratio against a threshold written as a decimal.
    private static let epsilon = 1e-9

    private struct SectionMatch {
        let section: EvalSection
        let expected: [EvalExpectedItem]
        let survived: Set<Int>
        let falseKeeps: [GroundedItem]

        var missing: [Int] {
            expected.indices.filter { !survived.contains($0) }
        }
    }

    /// - Parameters:
    ///   - decoys: the ungrounded items the stub emitted in this run. Empty
    ///     when the strategy that produced `summary` emits none.
    ///   - note: the rendered vault note for `summary`.
    static func score(fixture: EvalFixture, summary: SummaryWithGrounding, decoys: [EvalDecoy], note: String) -> EvalScore {
        let targets = fixture.expected.effectiveTargets
        let transcript = fixture.transcript
        let sections = [
            match(.actionItems, kept: summary.actionItems, expected: fixture.expected.actionItems, in: transcript),
            match(.decisions, kept: summary.decisions, expected: fixture.expected.decisions, in: transcript),
        ]
        let expectedCount = sections.reduce(0) { $0 + $1.expected.count }
        let survivedCount = sections.reduce(0) { $0 + $1.survived.count }
        let falseKeeps = sections.flatMap(\.falseKeeps)

        var failures: [String] = []
        failures += recallFailures(sections, expectedCount: expectedCount, survivedCount: survivedCount, targets: targets)
        if falseKeeps.count > targets.maxFalseKeeps {
            let texts = falseKeeps.map { "'\($0.text)'" }.joined(separator: ", ")
            failures.append("\(falseKeeps.count) false-keeps exceed max_false_keeps \(targets.maxFalseKeeps): \(texts)")
        }
        failures += decoyFailures(decoys, summary: summary)
        failures += dropFailures(reported: summary.quoteValidationDropCount, decoyCount: decoys.count, expectedCount: expectedCount, targets: targets)
        failures += noteFailures(sections, note: note)

        return EvalScore(
            fixtureName: fixture.name,
            groundingMethod: summary.groundingMethod,
            keptCount: summary.actionItems.count + summary.decisions.count,
            expectedCount: expectedCount,
            survivedCount: survivedCount,
            reportedDrops: summary.quoteValidationDropCount,
            falseKeeps: falseKeeps.count,
            failures: failures,
        )
    }

    // MARK: - Matching

    /// A kept item satisfies an expected one when its text is the same, its
    /// pointer's slice contains the expected quote, and its pointer lies inside
    /// the utterance that holds the expected span; a pointer stretched over a
    /// neighbouring utterance is not the grounding the item was expected to
    /// have. Each expected item is satisfied at most once, so a duplicate of it
    /// is a false-keep.
    private static func match(_ section: EvalSection, kept: [GroundedItem], expected: [EvalExpectedItem], in transcript: CanonicalTranscript) -> SectionMatch {
        let bytes = Array(transcript.text.utf8)
        var survived = Set<Int>()
        var falseKeeps: [GroundedItem] = []
        for item in kept {
            let pointer = item.grounding
            let sliced = EvalFixtures.slice(bytes, pointer.transcriptStart, pointer.transcriptEnd)
            let hit = expected.indices.first { index in
                let target = expected[index]
                guard
                    !survived.contains(index),
                    target.text == item.text,
                    sliced?.contains(target.quote) == true,
                    let owner = transcript.utterances.first(where: { $0.start <= target.transcriptStart && target.transcriptEnd <= $0.end })
                else {
                    return false
                }
                return owner.start <= pointer.transcriptStart && pointer.transcriptEnd <= owner.end
            }
            if let hit {
                survived.insert(hit)
            } else {
                falseKeeps.append(item)
            }
        }
        return SectionMatch(section: section, expected: expected, survived: survived, falseKeeps: falseKeeps)
    }

    // MARK: - Checks

    private static func recallFailures(_ sections: [SectionMatch], expectedCount: Int, survivedCount: Int, targets: EvalEffectiveTargets) -> [String] {
        let recall = expectedCount == 0 ? 1.0 : Double(survivedCount) / Double(expectedCount)
        guard recall + epsilon < targets.minRecall else { return [] }
        let missing = sections.flatMap { section in section.missing.map { "\(section.section.rawValue)[\($0)]" } }
        let shortfall = "recall \(format(recall)) (\(survivedCount) of \(expectedCount) expected items) is below min_recall \(format(targets.minRecall))"
        return ["\(shortfall); missing: \(missing.joined(separator: ", "))"]
    }

    /// A decoy is ungrounded by construction, so keeping one is a failure no
    /// `max_false_keeps` allowance may absorb.
    private static func decoyFailures(_ decoys: [EvalDecoy], summary: SummaryWithGrounding) -> [String] {
        decoys.compactMap { decoy in
            let kept = decoy.section == .actionItems ? summary.actionItems : summary.decisions
            guard kept.contains(where: { $0.text == decoy.text }) else { return nil }
            return "decoy kept in \(decoy.section.rawValue): '\(decoy.text)' passed grounding but is absent from the transcript"
        }
    }

    /// Drops that decoys account for are the validator working. Only the rest
    /// count against the drop rate, and every decoy must be reported dropped.
    private static func dropFailures(reported: Int, decoyCount: Int, expectedCount: Int, targets: EvalEffectiveTargets) -> [String] {
        var failures: [String] = []
        if reported < decoyCount {
            failures.append("\(reported) drops reported for \(decoyCount) decoys emitted")
        }
        let unexpected = max(0, reported - decoyCount)
        let rate = Double(unexpected) / Double(max(expectedCount, 1))
        if rate > targets.maxDropRate + epsilon {
            failures.append("drop rate \(format(rate)) (\(unexpected) unexpected drops) exceeds max_drop_rate \(format(targets.maxDropRate))")
        }
        return failures
    }

    /// Every expected item that survived must be in the note, in its own
    /// section, as `- text` with a `> ` quote line directly beneath it.
    private static func noteFailures(_ sections: [SectionMatch], note: String) -> [String] {
        var failures: [String] = []
        for section in sections {
            let heading = section.section == .actionItems ? "Action Items" : "Decisions"
            let body = noteSection(heading, in: note)
            for index in section.survived.sorted() {
                let item = section.expected[index]
                let label = "\(section.section.rawValue)[\(index)]"
                guard let quoteLine = quoteLine(forItemText: item.text, in: body) else {
                    failures.append("note is missing the text of \(label) under '## \(heading)'")
                    continue
                }
                let trimmed = quoteLine.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("> ") || !trimmed.contains(item.quote) {
                    failures.append("note has no '> ' line holding the quote of \(label)")
                }
            }
        }
        return failures
    }

    // MARK: - Note parsing

    /// The lines after `## <heading>` up to the next `## ` heading, or none
    /// when the heading is absent.
    private static func noteSection(_ heading: String, in note: String) -> String {
        let lines = note.split(separator: "\n", omittingEmptySubsequences: false)
        guard let start = lines.firstIndex(where: { $0 == "## \(heading)" }) else { return "" }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("## ") } ?? rest.endIndex
        return rest[..<end].joined(separator: "\n")
    }

    /// The line directly after the `- <text>` bullet, or nil when no bullet
    /// line is exactly that text.
    private static func quoteLine(forItemText text: String, in body: String) -> String? {
        let bullet = "- \(text)\n"
        var searchStart = body.startIndex
        while let range = body.range(of: bullet, range: searchStart ..< body.endIndex) {
            let startsLine = range.lowerBound == body.startIndex || body[body.index(before: range.lowerBound)] == "\n"
            if startsLine {
                return String(body[range.upperBound...].prefix { $0 != "\n" })
            }
            searchStart = range.upperBound
        }
        return nil
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
