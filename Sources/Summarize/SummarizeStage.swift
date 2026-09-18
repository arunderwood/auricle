import Core
import Foundation
import Orchestrator
import State
import SummarizerInterface
import Telemetry

/// The `summarize` stage entry point: reads `transcript.json` (and
/// `attribution.json` when present) from the meeting's cache directory, runs
/// `SummarizerOrchestrator`, and writes the `summary.json` the persist stage
/// reads. The whole body runs inside `StageRunner.run`'s `work` closure — this
/// type never writes `stage_events` or `meetings.state` itself, and every
/// failure is folded into a `summarization_failed` outcome rather than
/// thrown.
///
/// There is no calendar source or glossary builder yet, so the stage always
/// produces the unenriched-calendar variant of the artifact; the glossary is
/// whatever the caller injects.
public enum SummarizeStage {
    private static let summaryArtifactName = "summary.json"
    private static let summarySchemaVersion = 1
    private static let transcriptArtifactName = "transcript.json"

    /// Completes into `summarizing`, the state persist's own first
    /// transaction re-asserts, because no state sits between the two stages.
    ///
    /// Throws `StateStoreError.meetingNotFound` when `meetingID` has no row,
    /// before anything is recorded: `StageRunner.run`'s first transaction
    /// cannot start for a meeting that does not exist, and where foreign
    /// keys are enforced it would fail with a `DatabaseError` instead of a
    /// typed error the caller can act on.
    public static func run(
        meetingID: MeetingID,
        stateStore: StateStore,
        stageRunner: StageRunner,
        telemetryRecorder: TelemetryRecorder,
        orchestrator: SummarizerOrchestrator,
        glossary: Glossary,
        config: SummarizerConfig,
        timeZone: TimeZone = .current,
    ) async throws -> StageRunner.StageOutcome {
        guard let meeting = try await stateStore.fetchMeeting(id: meetingID.rawValue) else {
            throw StateStoreError.meetingNotFound(id: meetingID.rawValue)
        }
        let captureStartedAt = meeting.captureStartedAt
        return try await stageRunner.run(stage: .summarize, meetingID: meetingID, activeState: .summarizing) {
            do {
                return try await summarize(
                    meetingID: meetingID,
                    captureStartedAt: captureStartedAt,
                    telemetryRecorder: telemetryRecorder,
                    orchestrator: orchestrator,
                    glossary: glossary,
                    config: config,
                    timeZone: timeZone,
                )
            } catch {
                let classified = failure(for: error)
                return .failed(
                    targetState: .summarizationFailed,
                    errorClass: classified.errorClass,
                    errorMessage: classified.message,
                )
            }
        }
    }

    /// The process exit code for `__internal-stage summarize`: 0 on success,
    /// 2 (Decision 1.5's state error) on any failure.
    public static func exitCode(for outcome: StageRunner.StageOutcome) -> Int32 {
        switch outcome {
        case .completed: 0
        case .failed: 2
        }
    }

    // MARK: - Stage body

    /// Everything that can fail cheaply — reading and validating the inputs,
    /// and building the transcript segments — happens before the summarizer
    /// call, so a bad input never costs an API call.
    private static func summarize(
        meetingID: MeetingID,
        captureStartedAt: String?,
        telemetryRecorder: TelemetryRecorder,
        orchestrator: SummarizerOrchestrator,
        glossary: Glossary,
        config: SummarizerConfig,
        timeZone: TimeZone,
    ) async throws -> StageRunner.StageOutcome {
        let cacheDirectory = try resolveCacheDirectory(for: meetingID)
        let transcript = try readTranscript(in: cacheDirectory)
        let speakers = try AttributionSpeakers.read(in: cacheDirectory)
        let captureStartedAtDate = try parseCaptureStartedAt(captureStartedAt)

        let transcriptBytes = Array(transcript.text.utf8)
        let segments = try SummaryArtifactMapper.transcriptSegments(
            of: transcript,
            transcriptBytes: transcriptBytes,
            speakers: speakers,
        )

        let outcome = try await orchestrator.summarize(transcript: transcript, glossary: glossary, config: config)

        let artifact = try SummaryArtifactMapper.artifact(
            title: UnenrichedMeetingTitle.title(captureStartedAt: captureStartedAtDate, in: timeZone),
            grounded: outcome.summary,
            transcriptSegments: segments,
            needsAttribution: SummaryArtifactMapper.needsAttribution(transcript: transcript, speakers: speakers),
            transcriptBytes: transcriptBytes,
        )
        do {
            try CacheArtifactWriter.write(artifact, for: meetingID, named: summaryArtifactName, schemaVersion: summarySchemaVersion)
        } catch {
            throw SummarizeStageError.summaryWriteFailed
        }

        try await telemetryRecorder.record(
            meetingID: meetingID,
            patch: State.Telemetry(
                meetingID: meetingID.rawValue,
                quoteValidationDropCount: outcome.summary.quoteValidationDropCount,
                summarizationPath: "claude_api",
                summarizationModel: config.modelIdentifier,
                summarizationEffortBudget: config.effortLevel.rawValue,
                costUSD: outcome.summary.cost.costUSD,
            ),
        )

        return .completed(
            targetState: .summarizing,
            metadataJSON: encodeMetadataJSON(outcome: outcome, config: config),
        )
    }

    // MARK: - Inputs

    /// Decoded exactly once: the same `CanonicalTranscript` value is what the
    /// summarizer is given and what every quote and segment is sliced from,
    /// so the byte offsets a pointer carries mean the same thing at both ends.
    private static func readTranscript(in cacheDirectory: URL) throws -> CanonicalTranscript {
        let data: Data
        do {
            data = try Data(contentsOf: cacheDirectory.appendingPathComponent(transcriptArtifactName))
        } catch {
            throw SummarizeStageError.transcriptMissing
        }
        do {
            return try JSONDecoder().decode(CanonicalTranscript.self, from: data)
        } catch {
            throw SummarizeStageError.transcriptUndecodable
        }
    }

    /// A cache root that cannot be resolved means the transcript cannot be
    /// found either, so it is reported as the missing transcript it causes.
    private static func resolveCacheDirectory(for meetingID: MeetingID) throws -> URL {
        do {
            return try CacheArtifactWriter.cacheDirectory(for: meetingID)
        } catch {
            throw SummarizeStageError.transcriptMissing
        }
    }

    private static func parseCaptureStartedAt(_ captureStartedAt: String?) throws -> Date {
        guard let captureStartedAt, let date = ISO8601UTC.date(from: captureStartedAt) else {
            throw SummarizeStageError.captureStartedAtMissing
        }
        return date
    }

    // MARK: - metadata_json

    /// Encodes `SummarizeMeta` directly, not wrapped in
    /// `StageMetadata.summarize`, whose enum-keyed encoding would nest the
    /// payload under a `"summarize"` key — a different shape than Decision
    /// 4.5 specifies for this row. Encoding these scalar fields cannot fail
    /// in practice, and `work` must not crash the process on the one path
    /// that least needs an escape hatch, so a failure degrades to `{}`.
    private static func encodeMetadataJSON(outcome: SummarizerOrchestrator.Outcome, config: SummarizerConfig) -> String {
        let cost = outcome.summary.cost
        let meta = SummarizeMeta(
            modelID: config.modelIdentifier,
            effortBudget: config.effortLevel.rawValue,
            inputTokens: cost.inputTokens,
            outputTokens: cost.outputTokens,
            thinkingTokens: cost.thinkingTokens,
            costUSD: cost.costUSD,
            quoteValidationDropCount: outcome.summary.quoteValidationDropCount,
            groundingMethod: outcome.summary.groundingMethod.rawValue,
            fallbackTriggered: outcome.fallbackTriggered,
            fallbackErrorClass: outcome.primaryError?.stageErrorClass,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(meta),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return json
    }

    // MARK: - Failure classification

    /// Only a case name or a type name is ever recorded, never an error's own
    /// message: a foreign error can embed a path, a response body or transcript
    /// text, and `error_message` is persisted in `stage_events`.
    private static func failure(for error: Error) -> (errorClass: String, message: String) {
        switch error {
        case let stageError as SummarizeStageError:
            (stageError.errorClass, String(describing: stageError))
        case let summarizerError as SummarizerError:
            (summarizerError.stageErrorClass, String(describing: summarizerError))
        default:
            ("summarize_unexpected_error", String(reflecting: type(of: error)))
        }
    }
}
