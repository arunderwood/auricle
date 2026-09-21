import Attribute
import Capture
import ClaudeSummarizer
import Core
import Foundation
import Notifications
import Orchestrator
import Persist
import Pipeline
import State
import Telemetry
import Testing

// NFR-M5's CI-runnable smoke test. It drives `PipelineRunner` over a real
// state database, vault and cache directory. The transcriber, diarizer and
// Anthropic endpoint are stubs, so no model loads and nothing leaves the
// machine. `Fixtures/reference-tone.wav` is a synthetic 10 s sine tone:
// audio to import and cut snippets from, with no speech in it.

private let audioSeconds = 10.0
private let startedAt = "2026-04-28T14:30:00Z"

private let oneToOne = Scenario(
    label: "one-to-one, attributed",
    lines: [
        .init(speaker: "Speaker_1", text: "Thanks for joining the sync today."),
        .init(speaker: "Speaker_2", text: "I will send the revised budget to finance by Friday."),
        .init(speaker: "Speaker_1", text: "We decided to move the launch review to next Thursday."),
        .init(speaker: "Speaker_2", text: "Sounds good, talk then."),
    ],
    actionQuotes: ["I will send the revised budget to finance by Friday."],
    decisionQuotes: ["We decided to move the launch review to next Thursday."],
    speakerNames: ["Speaker_1": "[[Ben]]", "Speaker_2": "[[Sara]]"],
)

private let fourWayPublishAnyway = Scenario(
    label: "four speakers, publish anyway",
    lines: [
        .init(speaker: "Speaker_1", text: "Let us go around the table."),
        .init(speaker: "Speaker_2", text: "I can draft the rollout checklist this week."),
        .init(speaker: "Speaker_3", text: "I will book the review room."),
        .init(speaker: "Speaker_4", text: "We agreed to keep the current vendor."),
        .init(speaker: "Speaker_1", text: "Then that is settled."),
    ],
    actionQuotes: ["I can draft the rollout checklist this week.", "I will book the review room."],
    decisionQuotes: ["We agreed to keep the current vendor."],
    speakerNames: nil,
)

private struct Harness {
    let root: URL
    let vault: URL
    let store: StateStore
    let notifier = RecordingNotifier()
    let stub: AnthropicStub
    let scenario: Scenario

    init(scenario: Scenario) async throws {
        self.scenario = scenario
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        vault = root.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vault.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
        store = try StateStore.production(path: root.appendingPathComponent("state.sqlite").path)
        stub = try AnthropicStub(scenario: scenario)
    }

    func cleanUp(_ meetingID: MeetingID?) {
        stub.release()
        try? FileManager.default.removeItem(at: root)
        if let meetingID, let cache = try? CacheArtifactWriter.cacheDirectory(for: meetingID) {
            try? FileManager.default.removeItem(at: cache)
        }
    }

    func importReferenceAudio() async throws -> MeetingID {
        let audio = try #require(Bundle.module.url(forResource: "reference-tone", withExtension: "wav", subdirectory: "Fixtures"))
        let importer = AudioImporter(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store))
        return try await importer.importAudio(from: audio, startedAt: AudioImporter.parseStartedAt(startedAt), title: nil)
    }

    func runner() -> PipelineRunner {
        PipelineRunner(environment: PipelineRunner.Environment(
            stateStore: store,
            launcher: InProcessLauncher(
                store: store,
                scenario: scenario,
                audioSeconds: audioSeconds,
                orchestrator: ShippedSummarization.orchestrator(httpClient: stub.client),
            ),
            notifier: notifier,
            vaultPath: vault,
            meetingsSubdir: "Meetings",
            clock: PersistStage.TimeSource(timeZone: TimeZone(secondsFromGMT: 0)!),
        ))
    }
}

/// The `> ` quote lines that follow each bullet under `heading`, one string per bullet.
private func quotes(under heading: String, in note: String) -> [String] {
    var result: [String] = []
    var inSection = false
    var current: [String]?
    func flush() {
        if let current {
            result.append(current.joined(separator: "\n"))
        }
        current = nil
    }
    for line in note.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if line.hasPrefix("## ") {
            flush()
            inSection = line == "## \(heading)"
        } else if inSection {
            if line.hasPrefix("- ") {
                flush()
                current = []
            } else if line.hasPrefix("  >") {
                current?.append(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
        }
    }
    flush()
    return result
}

private extension Harness {
    /// A mapping is written against a diarization, so it can only follow one.
    func attribute(_ id: MeetingID, names: [String: String]?) async throws {
        guard let names else { return }
        let first = await runner().run(meetingID: id, options: RunOptions(to: .reviewDiarization))
        #expect(first == RunResult(exitCode: 0))
        try AttributionFile(speakers: names).write(for: id)
    }
}

/// The bold speaker at the head of each paragraph under `## Transcript`.
private func transcriptSpeakers(in note: String) -> [String] {
    note.split(separator: "\n").compactMap { line -> String? in
        guard line.hasPrefix("**"), let end = line.range(of: ":** ") else { return nil }
        return String(line[line.index(line.startIndex, offsetBy: 2) ..< end.lowerBound])
    }
}

/// Every transcript utterance is labelled Speaker_1, so the speakers in the
/// note can only have come from the diarization join.
private func expectSpeakersFromDiarization(in note: String, transcript: CanonicalTranscript, scenario: Scenario) {
    #expect(Set(transcript.utterances.map(\.speakerLabel)) == ["Speaker_1"])
    let expected = scenario.lines.map { line in scenario.speakerNames?[line.speaker] ?? "[[\(line.speaker)]]" }
    #expect(transcriptSpeakers(in: note) == expected)
    #expect(note.contains("auricle/needs-attribution") == (scenario.speakerNames == nil))
}

@Test(arguments: [oneToOne, fourWayPublishAnyway])
private func aReferenceRecordingReachesAwaitingVerificationWithAGroundedNote(scenario: Scenario) async throws {
    let harness = try await Harness(scenario: scenario)
    var meetingID: MeetingID?
    defer { harness.cleanUp(meetingID) }

    // Import (Story 4.8)
    let id = try await harness.importReferenceAudio()
    meetingID = id
    let imported = try #require(await harness.store.fetchMeeting(id: id.rawValue))
    #expect(imported.state == PipelineState.captured.rawValue)
    #expect(try FileManager.default.fileExists(atPath: #require(imported.audioCachePath)))

    try await harness.attribute(id, names: scenario.speakerNames)

    // Run
    let result = await harness.runner().run(meetingID: id, options: RunOptions(publishAnyway: scenario.speakerNames == nil))
    #expect(result == RunResult(exitCode: 0))
    #expect(harness.stub.requestCount == 1)

    // State: verification is a human act (Decision 4.3).
    let meeting = try #require(await harness.store.fetchMeeting(id: id.rawValue))
    #expect(meeting.state == PipelineState.awaitingVerification.rawValue)
    #expect(meeting.verifiedAt == nil)

    // Vault note at the FilenameResolver path (Story 2.2).
    let cache = try CacheArtifactWriter.cacheDirectory(for: id)
    let summary = try JSONDecoder().decode(SummaryArtifact.self, from: Data(contentsOf: cache.appendingPathComponent("summary.json")))
    let expectedName = FilenameResolver.resolve(meeting: MeetingForFilename(
        meetingID: id,
        captureDate: "2026-04-28",
        captureTime24h: "1430",
        calendarEventTitle: summary.calendarEventTitle,
        attendees: summary.attendees,
        selfWikilink: summary.selfWikilink,
    ))
    let expectedPath = harness.vault.appendingPathComponent("Meetings").appendingPathComponent(expectedName)
    let notePath = try #require(meeting.vaultNotePath)
    #expect(URL(fileURLWithPath: notePath).resolvingSymlinksInPath() == expectedPath.resolvingSymlinksInPath())
    #expect(harness.notifier.paths.value == [notePath])

    // Schema-valid frontmatter.
    let note = try String(contentsOfFile: notePath, encoding: .utf8)
    let frontmatter = try FrontmatterReader.read(noteContents: note)
    #expect(frontmatter.meetingID == id)
    #expect(frontmatter.schemaVersion == FrontmatterSchema.current)
    #expect(frontmatter.attendees == summary.attendees)

    // Every item is followed by a quote that matches the transcript literally,
    // and the ungrounded item the stub model added was dropped.
    let transcript = try JSONDecoder().decode(CanonicalTranscript.self, from: Data(contentsOf: cache.appendingPathComponent("transcript.json")))
    let actionQuotes = quotes(under: "Action Items", in: note)
    let decisionQuotes = quotes(under: "Decisions", in: note)
    #expect(actionQuotes == scenario.actionQuotes)
    #expect(decisionQuotes == scenario.decisionQuotes)
    for quote in actionQuotes + decisionQuotes {
        #expect(transcript.text.contains(quote))
    }
    #expect(!note.contains(AnthropicStub.ungroundedQuote))
    let telemetry = try #require(await harness.store.fetchTelemetry(meetingID: id.rawValue))
    #expect(telemetry.groundingMethod == "substring")
    #expect(telemetry.quoteValidationDropCount == 2)

    expectSpeakersFromDiarization(in: note, transcript: transcript, scenario: scenario)

    // Attribution outcome.
    #expect(telemetry.attributionCompletionPath == (scenario.speakerNames == nil ? "publish_anyway" : "cli_speakers_flag"))
}
