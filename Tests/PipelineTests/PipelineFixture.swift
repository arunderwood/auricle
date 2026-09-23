import Attribute
import Core
import DiarizerInterface
import Foundation
import GRDB
import Notifications
import Orchestrator
import Persist
import Pipeline
@testable import State
import Telemetry
import Testing
import Transcribe

final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

struct RecordedLaunch: Equatable, Sendable {
    let stage: PipelineStage
    let publishAnyway: Bool
}

/// A launcher whose workers are closures, so a test decides what each stage
/// does to the meeting without spawning anything.
final class ScriptedLauncher: StageWorkerLauncher {
    typealias Behavior = @Sendable (PipelineStage, Bool) async throws -> TranscribeRetryPolicy.Termination

    let launches = Locked<[RecordedLaunch]>([])
    private let behavior: Behavior

    init(_ behavior: @escaping Behavior) {
        self.behavior = behavior
    }

    var stages: [PipelineStage] {
        launches.value.map(\.stage)
    }

    func run(stage: PipelineStage, meetingID _: MeetingID, publishAnyway: Bool) async throws -> TranscribeRetryPolicy.Termination {
        launches.value.append(RecordedLaunch(stage: stage, publishAnyway: publishAnyway))
        return try await behavior(stage, publishAnyway)
    }
}

final class RecordingNotifier: Notifier {
    let paths = Locked<[String]>([])
    func fire(meetingID _: MeetingID, title _: String, vaultPath: String) async {
        paths.value.append(vaultPath)
    }

    func fireCaptureFailed(meetingID _: MeetingID, reason _: CaptureFailureReason) async {}
}

let fixtureTranscript = CanonicalTranscriptBuilder.build([
    (speakerLabel: "Speaker_1", text: "Hello there."),
    (speakerLabel: "Speaker_2", text: "Let us begin."),
])

let fixtureDiarization = DiarizationArtifact(segments: [
    DiarizedSegment(
        id: "seg_1", speakerLabel: "Speaker_1", startSeconds: 0, endSeconds: 5,
        utteranceIndex: DiarizedUtteranceRange(first: 0, last: 0), voiceProfile: DiarizedVoiceProfile(overlapRatio: 0),
    ),
    DiarizedSegment(
        id: "seg_2", speakerLabel: "Speaker_2", startSeconds: 5, endSeconds: 10,
        utteranceIndex: DiarizedUtteranceRange(first: 1, last: 1), voiceProfile: DiarizedVoiceProfile(overlapRatio: 0),
    ),
])

/// A real in-memory store, real `StageRunner`, and real vault directory. Only
/// the subprocess workers are scripted. The meeting's cache directory is the
/// real one, keyed by a fresh ULID, and `cleanUp()` removes both.
struct PipelineFixture {
    let meetingID = MeetingID.generate()
    let store: StateStore
    let stageRunner: StageRunner
    let notifier = RecordingNotifier()
    let directory: URL
    let vaultPath: URL
    let summaryText = Locked("A summary.")
    let rerunInstant = Locked("2026-05-15T12:00:00Z")

    init(state: PipelineState) async throws {
        store = try StateStore.forTesting(writer: DatabaseQueue())
        stageRunner = StageRunner(stateStore: store, stageEventLogger: StageEventLogger(stateStore: store))
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        vaultPath = directory.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: vaultPath.appendingPathComponent("Meetings"), withIntermediateDirectories: true)
        try await store.insertMeeting(Meeting(
            id: meetingID.rawValue, state: state.rawValue,
            createdAt: "2026-04-28T09:00:00Z", updatedAt: "2026-04-28T09:00:00Z",
            captureStartedAt: "2026-04-28T12:00:00Z", title: "Fixture meeting",
        ))
        try CacheArtifactWriter.write(fixtureTranscript, for: meetingID, named: "transcript.json", schemaVersion: 1)
        try CacheArtifactWriter.write(fixtureDiarization, for: meetingID, named: "diarization.json", schemaVersion: 1)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        if let cache = try? CacheArtifactWriter.cacheDirectory(for: meetingID) {
            try? FileManager.default.removeItem(at: cache)
        }
    }

    func plantMapping() throws {
        try AttributionFile(speakers: ["Speaker_1": "[[Ben]]", "Speaker_2": "[[Sara]]"]).write(for: meetingID)
    }

    func plantSummary(needsSummary: Bool = false, needsAttribution: Bool = false) throws {
        try CacheArtifactWriter.write(
            makeSummary(needsSummary: needsSummary, needsAttribution: needsAttribution),
            for: meetingID, named: "summary.json", schemaVersion: 1,
        )
    }

    func makeSummary(needsSummary: Bool, needsAttribution: Bool) -> SummaryArtifact {
        SummaryArtifact(
            title: "Fixture meeting", calendarEventTitle: "Fixture meeting", attendees: ["[[Ben]]"], selfWikilink: nil,
            needsAttribution: needsAttribution, needsCalendarEnrichment: false, needsSummary: needsSummary,
            summary: needsSummary ? "" : summaryText.value,
            actionItems: needsSummary ? [] : [QuotedItemArtifact(text: "Follow up", quote: "Hello there.")],
            decisions: [],
            transcriptSegments: [TranscriptSegmentArtifact(speaker: "[[Ben]]", text: "Hello there.")],
        )
    }

    /// What each worker does to the meeting, as the real one would: the
    /// stage's own transaction pair, and the artifact it leaves behind.
    /// `summarizeFails` makes summarize fail, and under `--publish-anyway`
    /// leave the stub instead, as the real stage does.
    func simulatedWorkers(summarizeFails: Bool = false, transcribeStatus: Locked<[Int32]>? = nil) -> ScriptedLauncher.Behavior {
        let runner = stageRunner
        let meetingID = meetingID
        let fixture = self
        return { stage, publishAnyway in
            switch stage {
            case .transcribe:
                if let queued = transcribeStatus?.value.first {
                    transcribeStatus?.value.removeFirst()
                    if queued != 0 {
                        _ = try await runner.run(stage: .transcribe, meetingID: meetingID, activeState: .transcribing) {
                            .failed(targetState: .transcriptionFailed, errorClass: "model_load_failed")
                        }
                        return .exited(queued)
                    }
                }
                _ = try await runner.run(stage: .transcribe, meetingID: meetingID, activeState: .transcribing) {
                    .completed(targetState: .transcribing)
                }
            case .reviewDiarization:
                _ = try await runner.run(stage: .reviewDiarization, meetingID: meetingID, activeState: .reviewingDiarization) {
                    .completed(targetState: .awaitingAttribution)
                }
            case .summarize:
                let outcome = try await runner.run(stage: .summarize, meetingID: meetingID, activeState: .summarizing) {
                    if summarizeFails, !publishAnyway {
                        return .failed(targetState: .summarizationFailed, errorClass: "summarizer_rate_limited")
                    }
                    try fixture.plantSummary(needsSummary: summarizeFails, needsAttribution: publishAnyway)
                    return .completed(targetState: .persisting)
                }
                return .exited(SummarizeExit.code(for: outcome))
            default:
                Issue.record("unexpected worker stage \(stage)")
                return .exited(1)
            }
            return .exited(0)
        }
    }

    func runner(
        launcher: any StageWorkerLauncher,
        vaultPath overrideVaultPath: URL?? = nil,
    ) -> PipelineRunner {
        let instant = ISO8601UTC.date(from: rerunInstant.value) ?? Date()
        return PipelineRunner(environment: PipelineRunner.Environment(
            stateStore: store,
            launcher: launcher,
            notifier: notifier,
            vaultPath: overrideVaultPath ?? vaultPath,
            meetingsSubdir: "Meetings",
            clock: PersistStage.TimeSource(now: { instant }, timeZone: TimeZone(identifier: "UTC") ?? .current),
        ))
    }

    func run(_ options: RunOptions, launcher: any StageWorkerLauncher) async -> RunResult {
        await runner(launcher: launcher).run(meetingID: meetingID, options: options)
    }

    func meeting() async throws -> Meeting {
        try #require(await store.fetchMeeting(id: meetingID.rawValue))
    }

    func events() async throws -> [StageEvent] {
        try await store.fetchStageEvents(meetingID: meetingID.rawValue).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    func meetingsDirectoryFiles() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: vaultPath.appendingPathComponent("Meetings").path).sorted()
    }
}

enum SummarizeExit {
    static func code(for outcome: StageRunner.StageOutcome) -> Int32 {
        switch outcome {
        case .completed: 0
        case .failed: 2
        }
    }
}
