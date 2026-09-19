import Core
import Foundation
import SummarizerInterface
import Testing

// Every test here feeds `EvalScorer` a hand-built summary and note, so each
// check is shown to fail on the input it exists to reject, not just to pass on
// good ones. Nothing runs a strategy.

// MARK: - Fixture

private let sendText = "Send the budget"
private let bookText = "Book the room"
private let shipText = "Ship on the 15th"
private let sendQuote = "I will send the budget by Friday."
private let shipQuote = "We decided to ship on the fifteenth."
private let bookQuote = "I'll book the room for Monday."

private let transcriptLines = [
    "Speaker_1: \(sendQuote)",
    "Speaker_2: \(shipQuote)",
    "Speaker_3: \(bookQuote)",
]

private let transcript: CanonicalTranscript = {
    var offset = 0
    var utterances: [CanonicalTranscript.Utterance] = []
    for line in transcriptLines {
        let label = String(line.prefix { $0 != ":" })
        utterances.append(.init(speakerLabel: label, start: offset, end: offset + line.utf8.count))
        offset += line.utf8.count + 1
    }
    return CanonicalTranscript(text: transcriptLines.joined(separator: "\n"), utterances: utterances)
}()

private func byteRange(of needle: String) -> (start: Int, end: Int) {
    guard let range = transcript.text.range(of: needle) else {
        Issue.record("'\(needle)' is not in the test transcript")
        return (0, 0)
    }
    let start = transcript.text.utf8.distance(from: transcript.text.startIndex, to: range.lowerBound)
    return (start, start + needle.utf8.count)
}

private func expectedItem(_ text: String, quote: String) -> EvalExpectedItem {
    let range = byteRange(of: quote)
    return EvalExpectedItem(text: text, quote: quote, transcriptStart: range.start, transcriptEnd: range.end)
}

private func makeFixture(targets: EvalTargets? = nil, withExpectedItems: Bool = true) -> EvalFixture {
    let expected = EvalExpectedFixture(
        schemaVersion: 1,
        source: EvalExpectedSource(kind: "test", title: "test", origin: "test", license: "test", attribution: "test"),
        speakers: [:],
        actionItems: withExpectedItems ? [expectedItem(sendText, quote: sendQuote), expectedItem(bookText, quote: bookQuote)] : [],
        decisions: withExpectedItems ? [expectedItem(shipText, quote: shipQuote)] : [],
        targets: targets,
        notes: "",
    )
    return EvalFixture(name: "demo", transcript: transcript, expected: expected)
}

// MARK: - Summary and note

/// A pointer at exactly `needle`, the way the substring strategy grounds.
private func exactPointer(_ needle: String) -> GroundingPointer {
    let range = byteRange(of: needle)
    return GroundingPointer(transcriptStart: range.start, transcriptEnd: range.end, sourceMethod: .substring)
}

/// A pointer at the whole utterance holding `needle`, the way the Citations
/// strategy grounds.
private func utterancePointer(holding needle: String) -> GroundingPointer {
    let range = byteRange(of: needle)
    let owner = transcript.utterances.first { $0.start <= range.start && range.end <= $0.end }
    return GroundingPointer(transcriptStart: owner?.start ?? 0, transcriptEnd: owner?.end ?? 0, sourceMethod: .citations)
}

private func makeSummary(
    actions: [GroundedItem],
    decisions: [GroundedItem],
    method: GroundingMethod = .substring,
    drops: Int = 0,
) -> SummaryWithGrounding {
    SummaryWithGrounding(
        schemaVersion: 1,
        summary: "Demo summary.",
        actionItems: actions,
        decisions: decisions,
        groundingMethod: method,
        cost: SummarizerCost(inputTokens: 0, outputTokens: 0, thinkingTokens: 0, costUSD: 0),
        quoteValidationDropCount: drops,
    )
}

private let fullActions = [
    GroundedItem(text: sendText, grounding: exactPointer(sendQuote)),
    GroundedItem(text: bookText, grounding: exactPointer(bookQuote)),
]
private let fullDecisions = [GroundedItem(text: shipText, grounding: exactPointer(shipQuote))]

/// A note shaped the way `FrontmatterRenderer` lays out the item sections.
private func makeNote(actions: [(text: String, quoteLine: String)], decisions: [(text: String, quoteLine: String)]) -> String {
    func section(_ heading: String, _ items: [(text: String, quoteLine: String)]) -> String {
        guard !items.isEmpty else { return "## \(heading)" }
        let bullets = items.map { "- \($0.text)\n  > \($0.quoteLine)" }.joined(separator: "\n")
        return "## \(heading)\n\n\(bullets)"
    }
    return ["---\ntitle: \"Demo\"\n---", "Demo summary.", section("Action Items", actions), section("Decisions", decisions), "## Transcript"]
        .joined(separator: "\n\n") + "\n"
}

private let fullNote = makeNote(
    actions: [(sendText, sendQuote), (bookText, bookQuote)],
    decisions: [(shipText, shipQuote)],
)

private func score(
    _ summary: SummaryWithGrounding,
    fixture: EvalFixture = makeFixture(),
    decoys: [EvalDecoy] = [],
    note: String = fullNote,
) -> EvalScore {
    EvalScorer.score(fixture: fixture, summary: summary, decoys: decoys, note: note)
}

private func mentions(_ score: EvalScore, _ needle: String) -> Bool {
    score.failures.contains { $0.contains(needle) }
}

private let decoys = [
    EvalDecoy(section: .actionItems, text: "Decoy action item", quote: "absent one"),
    EvalDecoy(section: .decisions, text: "Decoy decision", quote: "absent two"),
]

// MARK: - Tests

struct SummarizeEvalHarnessScoring {
    @Test func everyExpectedItemKeptAndRenderedPasses() {
        let result = score(makeSummary(actions: fullActions, decisions: fullDecisions))

        #expect(result.passed)
        #expect(result.failures.isEmpty)
        #expect(result.keptCount == 3)
        #expect(result.survivedCount == 3)
        #expect(result.falseKeeps == 0)
    }

    @Test func aPointerCoveringTheWholeUtteranceStillSurvives() {
        let actions = [
            GroundedItem(text: sendText, grounding: utterancePointer(holding: sendQuote)),
            GroundedItem(text: bookText, grounding: utterancePointer(holding: bookQuote)),
        ]
        let decisions = [GroundedItem(text: shipText, grounding: utterancePointer(holding: shipQuote))]
        let note = makeNote(
            actions: [(sendText, "Speaker_1: \(sendQuote)"), (bookText, "Speaker_3: \(bookQuote)")],
            decisions: [(shipText, "Speaker_2: \(shipQuote)")],
        )

        let result = score(makeSummary(actions: actions, decisions: decisions, method: .citations), note: note)

        #expect(result.passed)
        #expect(result.survivedCount == 3)
    }

    @Test func decoysReportedDroppedAreTheValidatorWorkingNotARegression() {
        let result = score(makeSummary(actions: fullActions, decisions: fullDecisions, drops: 2), decoys: decoys)

        #expect(result.passed)
        #expect(result.reportedDrops == 2)
        #expect(result.summaryLine.contains("dropped 2"))
    }

    @Test func aKeptDecoyFailsEvenWhenFalseKeepsAreAllowed() {
        let keptDecoy = GroundedItem(text: "Decoy action item", grounding: exactPointer(sendQuote))
        let tolerant = makeFixture(targets: EvalTargets(maxFalseKeeps: 5))

        let result = score(
            makeSummary(actions: fullActions + [keptDecoy], decisions: fullDecisions, drops: 1),
            fixture: tolerant,
            decoys: decoys,
        )

        #expect(!result.passed)
        #expect(mentions(result, "decoy kept in action_items"))
        #expect(!mentions(result, "max_false_keeps"))
    }

    @Test func aFixtureWithNoExpectedItemsPassesWhenNothingIsKept() {
        let strict = makeFixture(targets: EvalTargets(minRecall: 1.0, maxFalseKeeps: 0), withExpectedItems: false)
        let note = makeNote(actions: [], decisions: [])

        let result = score(makeSummary(actions: [], decisions: [], drops: 2), fixture: strict, decoys: decoys, note: note)

        #expect(result.passed)
        #expect(result.summaryLine == "Fixture demo: kept 0 items (0 expected) · dropped 2 · false-keeps 0 · grounding_method=substring")
    }

    @Test func anItemKeptWhereNothingIsExpectedIsAFalseKeep() {
        let strict = makeFixture(targets: EvalTargets(minRecall: 1.0, maxFalseKeeps: 0), withExpectedItems: false)
        let invented = GroundedItem(text: "Invented", grounding: exactPointer(sendQuote))

        let result = score(makeSummary(actions: [invented], decisions: []), fixture: strict, note: makeNote(actions: [], decisions: []))

        #expect(!result.passed)
        #expect(result.falseKeeps == 1)
        #expect(mentions(result, "max_false_keeps 0"))
    }

    @Test func aMissingExpectedItemFailsRecallNamingItsSectionAndIndex() {
        let result = score(makeSummary(actions: [fullActions[0]], decisions: []))

        #expect(!result.passed)
        #expect(mentions(result, "min_recall"))
        #expect(mentions(result, "action_items[1]"))
        #expect(mentions(result, "decisions[0]"))
        #expect(!mentions(result, "action_items[0]"))
    }

    @Test func recallAtOrAboveTheTargetToleratesAMissingItem() {
        let tolerant = makeFixture(targets: EvalTargets(minRecall: 0.6))
        let note = makeNote(actions: [(sendText, sendQuote)], decisions: [(shipText, shipQuote)])

        let result = score(makeSummary(actions: [fullActions[0]], decisions: fullDecisions), fixture: tolerant, note: note)

        #expect(result.passed)
        #expect(result.survivedCount == 2)
    }

    @Test func aPointerAtTheWrongTextIsNotCountedAsSurvived() {
        let misdirected = GroundedItem(text: sendText, grounding: exactPointer(shipQuote))

        let result = score(makeSummary(actions: [misdirected, fullActions[1]], decisions: fullDecisions))

        #expect(result.survivedCount == 2)
        #expect(result.falseKeeps == 1)
        #expect(mentions(result, "action_items[0]"))
        #expect(!result.passed)
    }

    @Test func aPointerSpanningTheOwnerAndTheNextUtteranceIsNotCountedAsSurvived() {
        let owner = transcript.utterances[0]
        let widened = GroundedItem(
            text: sendText,
            grounding: GroundingPointer(transcriptStart: owner.start, transcriptEnd: transcript.utterances[1].end, sourceMethod: .citations),
        )

        let result = score(makeSummary(actions: [widened, fullActions[1]], decisions: fullDecisions, method: .citations))

        #expect(result.survivedCount == 2)
        #expect(result.falseKeeps == 1)
        #expect(mentions(result, "action_items[0]"))
        #expect(!result.passed)
    }

    @Test func anExactQuotePointerInsideItsOwnerStillSurvives() {
        let result = score(makeSummary(actions: fullActions, decisions: fullDecisions))

        #expect(result.survivedCount == 3)
        #expect(result.falseKeeps == 0)
        #expect(result.passed)
    }

    @Test func aPointerOutsideTheTranscriptFailsInsteadOfTrapping() {
        let outOfRange = GroundedItem(
            text: sendText,
            grounding: GroundingPointer(transcriptStart: 0, transcriptEnd: 10000, sourceMethod: .substring),
        )

        let result = score(makeSummary(actions: [outOfRange, fullActions[1]], decisions: fullDecisions))

        #expect(result.survivedCount == 2)
        #expect(!result.passed)
    }

    @Test func anExtraGroundedItemIsAFalseKeepAndFailsOnlyPastTheAllowance() {
        let extra = GroundedItem(text: "Extra", grounding: exactPointer(bookQuote))
        let summary = makeSummary(actions: fullActions + [extra], decisions: fullDecisions)

        let allowed = score(summary)
        let strict = score(summary, fixture: makeFixture(targets: EvalTargets(maxFalseKeeps: 0)))

        #expect(allowed.falseKeeps == 1)
        #expect(allowed.passed)
        #expect(!strict.passed)
        #expect(mentions(strict, "max_false_keeps 0"))
    }

    @Test func aDuplicateOfAnExpectedItemIsAFalseKeep() {
        let summary = makeSummary(actions: fullActions + [fullActions[0]], decisions: fullDecisions)

        let result = score(summary, fixture: makeFixture(targets: EvalTargets(maxFalseKeeps: 0)))

        #expect(result.falseKeeps == 1)
        #expect(!result.passed)
    }

    @Test func aNoteWithoutAnItemsTextFails() {
        let note = makeNote(actions: [(sendText, sendQuote)], decisions: [(shipText, shipQuote)])

        let result = score(makeSummary(actions: fullActions, decisions: fullDecisions), note: note)

        #expect(!result.passed)
        #expect(mentions(result, "note is missing the text of action_items[1]"))
    }

    @Test func aNoteWithoutTheQuoteLineFails() {
        let bulletOnly = fullNote.replacingOccurrences(of: "\n  > \(shipQuote)", with: "")
        let wrongQuote = fullNote.replacingOccurrences(of: "  > \(sendQuote)", with: "  > something else")

        let missingLine = score(makeSummary(actions: fullActions, decisions: fullDecisions), note: bulletOnly)
        let missingQuote = score(makeSummary(actions: fullActions, decisions: fullDecisions), note: wrongQuote)

        #expect(mentions(missingLine, "decisions[0]"))
        #expect(mentions(missingQuote, "quote of action_items[0]"))
    }

    @Test func anItemTextUnderTheWrongHeadingDoesNotCount() {
        let swapped = makeNote(
            actions: [(sendText, sendQuote), (bookText, bookQuote), (shipText, shipQuote)],
            decisions: [],
        )

        let result = score(makeSummary(actions: fullActions, decisions: fullDecisions), note: swapped)

        #expect(mentions(result, "decisions[0]"))
    }

    @Test func dropsBeyondTheDecoysCountAgainstTheDropRate() {
        let summary = makeSummary(actions: fullActions, decisions: fullDecisions)

        let onePastDecoys = score(
            makeSummary(actions: fullActions, decisions: fullDecisions, drops: 3),
            decoys: decoys,
        )
        let onlyDecoys = score(makeSummary(actions: fullActions, decisions: fullDecisions, drops: 2), decoys: decoys)
        let noDecoys = score(makeSummary(actions: fullActions, decisions: fullDecisions, drops: 2))
        let allowed = score(
            makeSummary(actions: fullActions, decisions: fullDecisions, drops: 3),
            fixture: makeFixture(targets: EvalTargets(maxDropRate: 0.5)),
            decoys: decoys,
        )

        #expect(score(summary).passed)
        #expect(mentions(onePastDecoys, "max_drop_rate 0.20"))
        #expect(onlyDecoys.passed)
        #expect(mentions(noDecoys, "max_drop_rate"))
        #expect(allowed.passed)
    }

    @Test func fewerDropsThanDecoysFails() {
        let result = score(makeSummary(actions: fullActions, decisions: fullDecisions, drops: 1), decoys: decoys)

        #expect(!result.passed)
        #expect(mentions(result, "1 drops reported for 2 decoys emitted"))
    }

    @Test func aFixtureWithoutTargetsUsesTheProjectDefaults() throws {
        let fixture = try JSONDecoder().decode(EvalExpectedFixture.self, from: Data(Self.expectedJSON(targets: nil).utf8))

        #expect(fixture.targets == nil)
        #expect(fixture.effectiveTargets == EvalEffectiveTargets(minRecall: 0.8, maxFalseKeeps: 1, maxDropRate: 0.2))
    }

    @Test func partialTargetsKeepTheirOwnKeysAndDefaultTheRest() throws {
        let json = Self.expectedJSON(targets: #"{"min_recall": 0.5, "max_drop_rate": 0.4}"#)
        let fixture = try JSONDecoder().decode(EvalExpectedFixture.self, from: Data(json.utf8))

        #expect(fixture.effectiveTargets == EvalEffectiveTargets(minRecall: 0.5, maxFalseKeeps: 1, maxDropRate: 0.4))
    }

    @Test func aDeclaredMaxFalseKeepsOfZeroIsReadNotDefaulted() throws {
        let json = Self.expectedJSON(targets: #"{"max_false_keeps": 0}"#)
        let fixture = try JSONDecoder().decode(EvalExpectedFixture.self, from: Data(json.utf8))

        #expect(fixture.effectiveTargets == EvalEffectiveTargets(minRecall: 0.8, maxFalseKeeps: 0, maxDropRate: 0.2))
    }

    @Test func theSummaryLineHasTheDocumentedFormat() {
        let citations = score(makeSummary(actions: fullActions, decisions: fullDecisions, method: .citations))
        let extra = GroundedItem(text: "Extra", grounding: exactPointer(bookQuote))
        let substring = score(makeSummary(actions: fullActions + [extra], decisions: fullDecisions, drops: 2))

        #expect(citations.summaryLine == "Fixture demo: kept 3 items (3 expected) · dropped 0 · false-keeps 0 · grounding_method=citations")
        #expect(substring.summaryLine == "Fixture demo: kept 4 items (3 expected) · dropped 2 · false-keeps 1 · grounding_method=substring")
    }

    private static func expectedJSON(targets: String?) -> String {
        let targetsField = targets.map { #""targets": \#($0),"# } ?? ""
        return """
        {
          "schema_version": 1,
          "source": {"kind": "test", "title": "t", "origin": "o", "license": "l", "attribution": "a"},
          "speakers": {},
          "action_items": [],
          "decisions": [],
          \(targetsField)
          "notes": ""
        }
        """
    }
}
