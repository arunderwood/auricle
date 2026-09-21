import Core
import Foundation
import Orchestrator
import State
import Telemetry

/// The `attribute` stage's non-interactive entry: it turns a `--speakers`
/// mapping, a reused speakers map, or the all-placeholder choice into
/// `attribution.json` and moves the meeting to `summarizing`.
///
/// Everything that can be refused is checked before `StageRunner.run`, so a
/// bad mapping writes nothing and leaves the state alone. It never opens
/// `transcript.json`, `diarization.json` or `diarization_suggestions.json` for
/// write, and it logs no transcript text or speaker names.
public enum AttributionStage {
    public enum Mode: Sendable, Equatable {
        /// `--batch`, with the raw `--speakers` value if one was given. With
        /// none, the existing `attribution.json` speakers map is reused.
        case batch(speakers: String?)
        /// Every speaker keeps its `Speaker_N` placeholder and both correction
        /// arrays are empty. The path behind `auricle run --publish-anyway`.
        case publishAnyway
    }

    static let cliSpeakersFlagPath = "cli_speakers_flag"
    static let publishAnywayPath = "publish_anyway"

    private static let waitingStates: Set<PipelineState> = [.awaitingAttribution, .attributing]

    /// A published meeting is re-attributed only when the caller asks
    /// (`auricle run --reattribute`); attribution leaves its retention timer
    /// alone.
    private static let reattributableStates: Set<PipelineState> = waitingStates.union([
        .awaitingVerification, .published, .publishedPartial,
    ])

    private static let log = Log(category: "attribution-stage")

    private struct Plan {
        /// `nil` when the file on disk is already what the stage wants.
        let file: AttributionFile?
        let completionPath: String
        let speakerCount: Int
        let namedCount: Int
    }

    /// Throws `StateStoreError.meetingNotFound` for an unknown meeting and an
    /// `AttributionStageError` for anything refused, before anything is
    /// recorded. A write that fails inside the stage throws too, leaving the
    /// meeting in `attributing`, which has no stale-detection budget, so a
    /// retry is accepted from there.
    public static func run(
        meetingID: MeetingID,
        mode: Mode,
        stateStore: StateStore,
        stageRunner: StageRunner,
        telemetryRecorder: TelemetryRecorder,
        glossary: Glossary = Glossary(),
        reattribute: Bool = false,
    ) async throws -> StageRunner.StageOutcome {
        guard let meeting = try await stateStore.fetchMeeting(id: meetingID.rawValue) else {
            throw StateStoreError.meetingNotFound(id: meetingID.rawValue)
        }
        guard let state = PipelineState(rawValue: meeting.state), (reattribute ? reattributableStates : waitingStates).contains(state) else {
            throw AttributionStageError.wrongState(current: meeting.state)
        }
        let plan = try makePlan(meetingID: meetingID, mode: mode, glossary: glossary)

        return try await stageRunner.run(stage: .attribute, meetingID: meetingID, activeState: .attributing, expectedState: state) {
            if let file = plan.file {
                do {
                    try file.write(for: meetingID)
                } catch {
                    log.error("attribution write failed", ["error": .publicSafe(String(reflecting: type(of: error)))])
                    throw AttributionStageError.attributionWriteFailed
                }
            }
            await recordTelemetry(plan.completionPath, meetingID: meetingID, recorder: telemetryRecorder)
            return .completed(targetState: .summarizing, metadataJSON: metadata(plan))
        }
    }

    public static func exitCode(for outcome: StageRunner.StageOutcome) -> Int32 {
        switch outcome {
        case .completed: WorkerExitCode.success
        case .failed: WorkerExitCode.stateError
        }
    }

    /// The whole non-interactive run as a process status, for the thin CLI verb.
    public static func execute(
        meetingID: MeetingID,
        mode: Mode,
        stateStore: StateStore,
        stageRunner: StageRunner,
        telemetryRecorder: TelemetryRecorder,
        glossary: Glossary = Glossary(),
        reattribute: Bool = false,
    ) async -> WorkerExitStatus {
        do {
            let outcome = try await run(
                meetingID: meetingID, mode: mode, stateStore: stateStore, stageRunner: stageRunner,
                telemetryRecorder: telemetryRecorder, glossary: glossary, reattribute: reattribute,
            )
            let code = exitCode(for: outcome)
            return WorkerExitStatus(code: code, message: code == WorkerExitCode.success ? nil : "could not record the attribution transition.")
        } catch StateStoreError.meetingNotFound {
            return WorkerExitStatus(code: WorkerExitCode.meetingNotFound, message: "no meeting has the given ID.")
        } catch let error as AttributionStageError {
            let code = error == .attributionWriteFailed ? WorkerExitCode.stateError : WorkerExitCode.callerError
            return WorkerExitStatus(code: code, message: error.userMessage)
        } catch {
            return WorkerExitStatus(code: WorkerExitCode.stateError, message: "could not record its progress (\(String(reflecting: type(of: error)))).")
        }
    }

    // MARK: - Planning

    private static func makePlan(meetingID: MeetingID, mode: Mode, glossary: Glossary) throws -> Plan {
        let inputs: AttributionInputs
        do {
            inputs = try AttributionInputs.load(for: meetingID)
        } catch AttributionInputs.LoadError.attributionUnreadable {
            throw AttributionStageError.attributionUnreadable
        } catch {
            throw AttributionStageError.diarizationUnreadable
        }
        let labels = inputs.diarization.speakerLabels

        switch mode {
        case .publishAnyway:
            let speakers = Dictionary(uniqueKeysWithValues: labels.map { ($0, $0) })
            return Plan(file: AttributionFile(speakers: speakers), completionPath: publishAnywayPath, speakerCount: labels.count, namedCount: 0)

        case let .batch(raw?):
            let speakers: [String: String]
            do {
                speakers = try SpeakersFlagParser.parse(raw, labels: labels, glossary: glossary)
            } catch {
                throw AttributionStageError.invalidSpeakers(error)
            }
            let file = AttributionFile(
                speakers: speakers,
                segmentOverrides: inputs.existing?.segmentOverrides ?? [],
                segmentSplits: inputs.existing?.segmentSplits ?? [],
            )
            return Plan(file: file, completionPath: cliSpeakersFlagPath, speakerCount: labels.count, namedCount: named(speakers))

        case .batch(nil):
            guard let existing = inputs.existing, !existing.speakers.isEmpty else { throw AttributionStageError.noSpeakerMapping }
            return Plan(file: nil, completionPath: cliSpeakersFlagPath, speakerCount: labels.count, namedCount: named(existing.speakers))
        }
    }

    private static func named(_ speakers: [String: String]) -> Int {
        speakers.values.count { !SpeakerNaming.isPlaceholder(SpeakerNaming.bareName($0)) && !SpeakerNaming.bareName($0).isEmpty }
    }

    // MARK: - Telemetry and metadata

    /// Best-effort: the file is already on disk, and a telemetry failure must
    /// not turn it into a failed stage.
    private static func recordTelemetry(_ path: String, meetingID: MeetingID, recorder: TelemetryRecorder) async {
        do {
            try await recorder.record(meetingID: meetingID, patch: AttributeTelemetryPatch(attributionCompletionPath: path))
        } catch {
            log.warn("recording attribution telemetry failed", ["error": .publicSafe(String(reflecting: type(of: error)))])
        }
    }

    /// Counts only, never names. A failure degrades to `{}` because `work` must
    /// not crash on the row that records it.
    private static func metadata(_ plan: Plan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let meta = AttributionStageMeta(completionPath: plan.completionPath, speakerCount: plan.speakerCount, namedCount: plan.namedCount)
        guard let data = try? encoder.encode(meta), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}

private struct AttributionStageMeta: Encodable {
    let completionPath: String
    let speakerCount: Int
    let namedCount: Int

    enum CodingKeys: String, CodingKey {
        case completionPath = "completion_path"
        case speakerCount = "speaker_count"
        case namedCount = "named_count"
    }
}
