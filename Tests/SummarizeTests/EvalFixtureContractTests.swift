import Core
import Foundation
import Testing

// MARK: - Fixture model

private struct ExpectedSource: Decodable {
    let kind: String
    let title: String
    let origin: String
    let license: String
    let attribution: String
}

private struct ExpectedItem: Decodable {
    let text: String
    let quote: String
    let transcriptStart: Int
    let transcriptEnd: Int

    enum CodingKeys: String, CodingKey {
        case text
        case quote
        case transcriptStart = "transcript_start"
        case transcriptEnd = "transcript_end"
    }
}

private struct ExpectedTargets: Decodable {
    let minRecall: Double
    let maxFalseKeeps: Int

    enum CodingKeys: String, CodingKey {
        case minRecall = "min_recall"
        case maxFalseKeeps = "max_false_keeps"
    }
}

private struct ExpectedFixture: Decodable {
    let schemaVersion: Int
    let source: ExpectedSource
    let speakers: [String: String]
    let actionItems: [ExpectedItem]
    let decisions: [ExpectedItem]
    let targets: ExpectedTargets
    let notes: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case source
        case speakers
        case actionItems = "action_items"
        case decisions
        case targets
        case notes
    }
}

private struct EvalFixture {
    let transcript: CanonicalTranscript
    let expected: ExpectedFixture
}

private enum EvalFixtures {
    static var directory: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("Fixtures/eval", isDirectory: true)
    }

    /// Every subdirectory holding a `transcript.json`, so a new fixture is
    /// covered by these tests the moment it is added.
    static var names: [String] {
        guard let directory,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else {
            return []
        }
        return entries
            .filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).appendingPathComponent("transcript.json").path) }
            .sorted()
    }

    static func load(_ name: String) throws -> EvalFixture {
        let base = try #require(directory).appendingPathComponent(name, isDirectory: true)
        let transcript = try JSONDecoder().decode(CanonicalTranscript.self, from: Data(contentsOf: base.appendingPathComponent("transcript.json")))
        let expected = try JSONDecoder().decode(ExpectedFixture.self, from: Data(contentsOf: base.appendingPathComponent("expected.json")))
        return EvalFixture(transcript: transcript, expected: expected)
    }
}

/// The UTF-8 byte range as text, or nil when it is out of bounds or splits a
/// scalar, so a bad pointer fails an assertion instead of trapping.
private func slice(_ bytes: [UInt8], _ start: Int, _ end: Int) -> String? {
    guard start >= 0, start <= end, end <= bytes.count else { return nil }
    return String(bytes: bytes[start ..< end], encoding: .utf8)
}

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

        let piece = slice(bytes, utterance.start, utterance.end)
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
    #expect((0 ... 1).contains(expected.targets.minRecall))
    #expect(expected.targets.maxFalseKeeps >= 0)

    for item in expected.actionItems + expected.decisions {
        #expect(!item.text.isEmpty)
        #expect(!item.quote.isEmpty)
        #expect(slice(bytes, item.transcriptStart, item.transcriptEnd) == item.quote)

        // A quote sits inside one utterance and after its `Speaker_N: ` label.
        let owner = utterances.first { $0.start <= item.transcriptStart && item.transcriptEnd <= $0.end }
        #expect(owner != nil)
        if let owner {
            #expect(item.transcriptStart >= owner.start + owner.speakerLabel.utf8.count + 2)
        }
    }
}

@Test(arguments: EvalFixtures.names)
func fixtureIsAttributedInTheNotice(name: String) throws {
    let notice = try String(contentsOf: #require(EvalFixtures.directory).appendingPathComponent("NOTICE.md"), encoding: .utf8)
    #expect(notice.contains("`\(name)`"))
}
