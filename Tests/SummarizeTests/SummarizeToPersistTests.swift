import Core
import Foundation
import Persist
import State
import SummarizerInterface
import Testing

/// Runs `SummarizeStage` and then `PersistStage` back to back over each eval
/// fixture, with only the summarizer stubbed. The `summary.json` the first
/// stage writes into the meeting's real cache directory is the only thing
/// handed to the second, which is the contract neither stage's own tests cross.
@Test(arguments: EvalFixtures.names)
func summarizeThenPersistPublishesANoteWithEveryExpectedQuoteAsABlockquote(name: String) async throws {
    let eval = try EvalFixtures.load(name)
    let spanning = try makeSpanningItem(over: eval.transcript)

    let fixture = try await StageFixture()
    defer { fixture.cleanUp() }
    try fixture.plantTranscript(eval.transcript)

    let vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let meetingsSubdir = vault.appendingPathComponent("Meetings")
    try FileManager.default.createDirectory(at: meetingsSubdir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: vault) }

    let grounded = makeStageGrounded(
        actionItems: eval.expected.actionItems.map(groundedItem) + [spanning.item],
        decisions: eval.expected.decisions.map(groundedItem),
    )
    let summarized = try await fixture.run(primary: StageStubStrategy(.success(grounded)))
    guard case .completed = summarized else {
        Issue.record("expected the summarize stage to complete, got \(summarized)")
        return
    }

    let persisted = try await PersistStage.run(
        meetingID: fixture.meetingID,
        isRepublish: false,
        cacheDirectory: CacheArtifactWriter.cacheDirectory(for: fixture.meetingID),
        vaultPath: vault,
        meetingsSubdir: "Meetings",
        stateStore: fixture.store,
        stageRunner: fixture.runner,
    )
    guard case let .completed(targetState, _) = persisted else {
        Issue.record("expected the persist stage to complete, got \(persisted)")
        return
    }
    #expect(targetState == .published)
    #expect(try await fixture.state() == "published")
    #expect(try await fixture.events().map { "\($0.stage):\($0.event)" } == [
        "summarize:started", "summarize:completed", "persist:started", "persist:completed",
    ])

    let notePath = try #require(try await fixture.store.fetchMeeting(id: fixture.meetingID.rawValue)?.vaultNotePath)
    let note = try String(contentsOfFile: notePath, encoding: .utf8)
    let lines = note.components(separatedBy: "\n")

    #expect(note.contains("auricle/needs-attribution"))
    #expect(note.contains("auricle/needs-calendar-enrichment"))
    #expect(note.contains("title: \"\(stageExpectedTitle)\""))

    for item in eval.expected.actionItems + eval.expected.decisions {
        #expect(containsConsecutive(blockquoteLines(for: item.quote), in: lines), "expected quote missing from \(name): \(item.quote)")
    }

    // The two-utterance quote spans a line break, so its second line only
    // stays inside the blockquote if the renderer prefixes every line.
    #expect(containsConsecutive(blockquoteLines(for: spanning.quote), in: lines), "spanning quote is not one blockquote in \(name)")

    let sectionLines = try quotedItemSectionLines(of: lines)
    let unquoted = sectionLines.filter { !$0.isEmpty && !$0.hasPrefix("- ") && !$0.hasPrefix("  >") && !$0.hasPrefix("## ") }
    #expect(unquoted.isEmpty, "lines outside the blockquote in \(name): \(unquoted)")
}

// MARK: - Helpers

private func groundedItem(_ expected: ExpectedItem) -> GroundedItem {
    GroundedItem(
        text: expected.text,
        grounding: GroundingPointer(
            transcriptStart: expected.transcriptStart,
            transcriptEnd: expected.transcriptEnd,
            sourceMethod: .citations,
        ),
    )
}

/// An item whose pointer covers the first two whole utterances, the way a
/// Citations pointer covers whole utterances, so its quote contains a `\n`.
private func makeSpanningItem(over transcript: CanonicalTranscript) throws -> (item: GroundedItem, quote: String) {
    let utterances = transcript.utterances
    let first = try #require(utterances.first)
    let second = try #require(utterances.dropFirst().first)
    let bytes = Array(transcript.text.utf8)
    let quote = try #require(String(bytes: bytes[first.start ..< second.end], encoding: .utf8))
    let item = GroundedItem(
        text: "Two utterances at once",
        grounding: GroundingPointer(transcriptStart: first.start, transcriptEnd: second.end, sourceMethod: .citations),
    )
    return (item, quote)
}

/// The note lines a quote renders to: each line of the quote behind `  > `, and
/// an empty line as a bare `  >`.
private func blockquoteLines(for quote: String) -> [String] {
    quote.components(separatedBy: "\n").map { $0.isEmpty ? "  >" : "  > \($0)" }
}

/// Whether `needle` appears as consecutive entries of `lines`, anywhere.
private func containsConsecutive(_ needle: [String], in lines: [String]) -> Bool {
    guard !needle.isEmpty, needle.count <= lines.count else { return false }
    return (0 ... lines.count - needle.count).contains { Array(lines[$0 ..< $0 + needle.count]) == needle }
}

/// Everything between the `Action Items` heading and the `Transcript` heading:
/// the two sections that carry quotes.
private func quotedItemSectionLines(of lines: [String]) throws -> [String] {
    let start = try #require(lines.firstIndex(of: "## Action Items"))
    let end = try #require(lines.firstIndex(of: "## Transcript"))
    return Array(lines[start ..< end])
}
