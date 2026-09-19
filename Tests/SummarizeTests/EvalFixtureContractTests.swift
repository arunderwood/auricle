import Core
import Foundation
import Testing

// MARK: - Tests

@Test func atLeastFiveFixturesExist() {
    #expect(EvalFixtures.names.count >= 5)
}

@Test(arguments: EvalFixtures.names)
func transcriptFollowsTheCanonicalForm(name: String) throws {
    let transcript = try EvalFixtures.load(name).transcript
    let utterances = transcript.utterances
    let text = transcript.text
    let bytes = Array(text.utf8)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

    #expect(text == text.precomposedStringWithCanonicalMapping)
    #expect(!text.contains("\r"))
    #expect(lines.count == utterances.count)
    #expect(utterances.last?.end == bytes.count)

    for (index, utterance) in utterances.enumerated() {
        let expectedStart = index == 0 ? 0 : utterances[index - 1].end + 1
        #expect(utterance.start == expectedStart)

        let piece = EvalFixtures.slice(bytes, utterance.start, utterance.end)
        #expect(piece == lines[index])
        #expect(piece?.hasPrefix("\(utterance.speakerLabel): ") == true)
        #expect(lines[index] == lines[index].trimmingCharacters(in: .whitespaces))
    }

    var seen: [String] = []
    for utterance in utterances where !seen.contains(utterance.speakerLabel) {
        seen.append(utterance.speakerLabel)
    }
    #expect(seen == (1 ... seen.count).map { "Speaker_\($0)" })
}

@Test(arguments: EvalFixtures.names)
func expectedItemsPointAtTheirQuotes(name: String) throws {
    let fixture = try EvalFixtures.load(name)
    let utterances = fixture.transcript.utterances
    let bytes = Array(fixture.transcript.text.utf8)
    let expected = fixture.expected

    #expect(expected.schemaVersion == 1)
    #expect(!expected.source.title.isEmpty)
    #expect(!expected.source.license.isEmpty)
    #expect(Set(expected.speakers.keys) == Set(utterances.map(\.speakerLabel)))

    let targets = expected.effectiveTargets
    #expect((0 ... 1).contains(targets.minRecall))
    #expect(targets.maxFalseKeeps >= 0)
    #expect((0 ... 1).contains(targets.maxDropRate))

    for item in expected.actionItems + expected.decisions {
        #expect(!item.text.isEmpty)
        #expect(!item.quote.isEmpty)
        #expect(EvalFixtures.slice(bytes, item.transcriptStart, item.transcriptEnd) == item.quote)

        // A quote sits inside one utterance and after its `Speaker_N: ` label.
        let owner = utterances.first { $0.start <= item.transcriptStart && item.transcriptEnd <= $0.end }
        #expect(owner != nil)
        if let owner {
            #expect(item.transcriptStart >= owner.start + owner.speakerLabel.utf8.count + 2)
        }
    }
}

/// `EvalTargets` ignores unknown keys and defaults absent ones, so a misspelt
/// key would silently fall back to the project default; the raw JSON is the
/// only place that can be seen.
@Test(arguments: EvalFixtures.names)
func targetsUseOnlyKnownKeysAndKeepTheirDeclaredValues(name: String) throws {
    let file = try #require(EvalFixtures.directory).appendingPathComponent(name, isDirectory: true).appendingPathComponent("expected.json")
    let root = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    let declared = root?["targets"] as? [String: Any] ?? [:]
    let effective = try EvalFixtures.load(name).expected.effectiveTargets
    let resolved: [String: Double] = [
        "min_recall": effective.minRecall,
        "max_false_keeps": Double(effective.maxFalseKeeps),
        "max_drop_rate": effective.maxDropRate,
    ]

    #expect(Set(declared.keys).isSubset(of: Set(resolved.keys)))
    for (key, value) in declared {
        #expect((value as? NSNumber)?.doubleValue == resolved[key], Comment(rawValue: "\(name): targets.\(key)"))
    }
}

@Test(arguments: EvalFixtures.names)
func fixtureIsAttributedInTheNotice(name: String) throws {
    let notice = try String(contentsOf: #require(EvalFixtures.directory).appendingPathComponent("NOTICE.md"), encoding: .utf8)
    #expect(notice.contains("`\(name)`"))
}
