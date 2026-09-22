import Core
import Foundation
import RecallBench
import SummarizerInterface

/// This test target's own directory, two levels below the repository root.
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

/// A throwaway directory standing in for a repository root, so a loader test
/// can name a manifest that is missing, malformed, or points at nothing.
struct TemporaryRoot {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("recall-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func writeManifest(_ contents: String) throws {
        try writeFixtureFile(RecallBenchFixtureLoader.manifestPath, contents: contents)
    }

    func writeFixtureFile(_ relativePath: String, contents: String) throws {
        let target = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicWriter.write(Data(contents.utf8), to: target)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// Every regular file under `directory`, as paths.
func filePaths(under directory: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else {
        return []
    }
    return enumerator.compactMap { entry in
        guard
            let url = entry as? URL,
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        else {
            return nil
        }
        return url.resolvingSymlinksInPath().path
    }
}

/// A transcript whose byte offsets are computed from the text it builds, so a
/// grounding pointer into an utterance always slices cleanly.
func makeTranscript(_ lines: [(speaker: String, body: String)]) -> CanonicalTranscript {
    var text = ""
    var utterances: [CanonicalTranscript.Utterance] = []
    for (index, line) in lines.enumerated() {
        if index > 0 {
            text += "\n"
        }
        let start = text.utf8.count
        text += "\(line.speaker): \(line.body)"
        utterances.append(CanonicalTranscript.Utterance(speakerLabel: line.speaker, start: start, end: text.utf8.count))
    }
    return CanonicalTranscript(text: text, utterances: utterances)
}

func makeSummary(actionItems: [GroundedItem], decisions: [GroundedItem] = [], costUSD: Double) -> SummaryWithGrounding {
    SummaryWithGrounding(
        schemaVersion: 1,
        summary: "A short summary.",
        actionItems: actionItems,
        decisions: decisions,
        groundingMethod: .substring,
        cost: SummarizerCost(inputTokens: 100, outputTokens: 20, thinkingTokens: 0, costUSD: costUSD),
        quoteValidationDropCount: 0,
    )
}

func groundedItem(_ text: String, of transcript: CanonicalTranscript, utterance index: Int) -> GroundedItem {
    let utterance = transcript.utterances[index]
    return GroundedItem(
        text: text,
        grounding: GroundingPointer(transcriptStart: utterance.start, transcriptEnd: utterance.end, sourceMethod: .substring),
    )
}

/// A stub arm: no network, no key, a fixed result.
struct StubSummarizer: SummarizerStrategy {
    enum Failure: Error { case refused }

    let result: Result<SummaryWithGrounding, Failure>

    func summarize(transcript _: CanonicalTranscript, glossary _: Glossary, config _: SummarizerConfig) async throws -> SummaryWithGrounding {
        try result.get()
    }
}

let scoreScriptURL = repoRoot.appendingPathComponent("Tests/regression/ami/score.py")

/// Whether `python3` is on `PATH`, decided by looking rather than by running.
///
/// This is read from `.enabled(if:)`, which swift-testing evaluates for every
/// gated test, concurrently and on the cooperative pool. Spawning a process
/// here blocked one of those threads inside the lazy global's `swift_once`
/// while the rest queued behind the token, which is enough to stall a narrow
/// pool before a single test body runs. A `PATH` walk answers the same
/// question without a subprocess and without blocking.
let python3IsAvailable: Bool = {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    return path.split(separator: ":").contains { directory in
        FileManager.default.isExecutableFile(atPath: "\(directory)/python3")
    }
}()

/// A reference fixture's `expected.json`, read by the tests that need its own
/// grounding pointers rather than invented ones.
struct ExpectedItems: Decodable {
    let actionItems: [ExpectedItem]
    let decisions: [ExpectedItem]

    enum CodingKeys: String, CodingKey {
        case actionItems = "action_items"
        case decisions
    }

    static func read(from directory: URL) throws -> ExpectedItems {
        let data = try Data(contentsOf: directory.appendingPathComponent("expected.json"))
        return try JSONDecoder().decode(ExpectedItems.self, from: data)
    }
}

struct ExpectedItem: Decodable {
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

    /// The item as a summarizer would have produced it: the fixture's own
    /// byte range, so the rendered quote is a verbatim transcript slice.
    var grounded: GroundedItem {
        GroundedItem(
            text: text,
            grounding: GroundingPointer(transcriptStart: transcriptStart, transcriptEnd: transcriptEnd, sourceMethod: .substring),
        )
    }
}
