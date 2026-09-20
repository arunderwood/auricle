import AIReviewerInterface
import Core
import DiarizerInterface
import Foundation
import Orchestrator
import State
import Telemetry

/// The `review-diarization` stage entry point. Flag off, it writes an empty
/// `diarization_suggestions.json` and moves on without reading anything. Flag
/// on, it hands `transcript.json` and `diarization.json` to the injected
/// reviewer under a time budget.
///
/// Every outcome targets `awaiting_attribution`. A reviewer that fails or
/// runs out of time leaves an empty stub and a `failed` row carrying the
/// class, never a `*_failed` state: the review is an aid, and the meeting
/// must not stall on it.
///
/// It depends on the `DiarizationReviewerStrategy` protocol only, and never
/// opens `transcript.json` or `diarization.json` for write.
public enum ReviewDiarizationStage {
    static let flagOffModelID = "flag_off"

    private static let transcriptArtifactName = "transcript.json"
    private static let diarizationArtifactName = "diarization.json"
    private static let suggestionsArtifactName = "diarization_suggestions.json"
    private static let log = Log(category: "review-diarization-stage")

    /// Throws `StateStoreError.meetingNotFound` when `meetingID` has no row,
    /// before anything is recorded.
    public static func run(
        meetingID: MeetingID,
        stateStore: StateStore,
        stageRunner: StageRunner,
        telemetryRecorder: TelemetryRecorder,
        reviewer: any DiarizationReviewerStrategy,
        settings: ReviewDiarizationSettings,
    ) async throws -> StageRunner.StageOutcome {
        guard try await stateStore.fetchMeeting(id: meetingID.rawValue) != nil else {
            throw StateStoreError.meetingNotFound(id: meetingID.rawValue)
        }
        return try await stageRunner.run(stage: .reviewDiarization, meetingID: meetingID, activeState: .reviewingDiarization) {
            let outcome = await review(meetingID: meetingID, reviewer: reviewer, settings: settings)
            await recordTelemetry(for: outcome, meetingID: meetingID, recorder: telemetryRecorder)
            return outcome.stageOutcome
        }
    }

    /// `WorkerExitCode.success` for a completed review and for a benign
    /// failure, `stateError` for a suggestions file that could not be written.
    public static func exitCode(for outcome: StageRunner.StageOutcome) -> Int32 {
        switch outcome {
        case .completed:
            WorkerExitCode.success
        case let .failed(_, errorClass, _, _):
            errorClass == ReviewDiarizationStageError.suggestionsWriteFailed.errorClass ? WorkerExitCode.stateError : WorkerExitCode.success
        }
    }

    // MARK: - Stage body

    private struct ReviewOutcome {
        let stageOutcome: StageRunner.StageOutcome
        /// `nil` when the suggestions file was never written.
        let telemetry: ReviewDiarizationTelemetryPatch?
    }

    private static func review(meetingID: MeetingID, reviewer: any DiarizationReviewerStrategy, settings: ReviewDiarizationSettings) async -> ReviewOutcome {
        guard settings.enabled else {
            let meta = meta(modelID: flagOffModelID, skipped: true)
            return writeStub(meetingID: meetingID, modelID: flagOffModelID, meta: meta, failure: nil)
        }

        let input: DiarizationReviewInput
        do {
            input = try readInput(for: meetingID)
        } catch {
            return writeFailureStub(meetingID: meetingID, settings: settings, error: .inputsUnreadable)
        }

        let result: AIReviewerResult<DiarizationSuggestion>
        do {
            result = try await withDeadline(seconds: settings.timeoutSeconds) {
                try await reviewer.review(input: input, config: AIReviewerConfig(modelID: settings.modelID))
            }
        } catch is DeadlineExceeded {
            return writeFailureStub(meetingID: meetingID, settings: settings, error: .reviewerTimeout)
        } catch {
            log.warn("diarization reviewer failed", ["error": .publicSafe(String(reflecting: type(of: error)))])
            return writeFailureStub(meetingID: meetingID, settings: settings, error: .reviewerFailed)
        }

        do {
            try CacheArtifactWriter.write(result, for: meetingID, named: suggestionsArtifactName, schemaVersion: AIReviewerResult<DiarizationSuggestion>.currentSchemaVersion)
        } catch {
            return writeFailed(paid: result.cost)
        }
        let meta = ReviewDiarizationMeta(
            modelID: result.cost.modelID,
            inputTokens: result.cost.inputTokens,
            outputTokens: result.cost.outputTokens,
            costUSD: result.cost.costUSD,
            suggestionsCount: result.suggestions.count,
            reviewSkipped: false,
        )
        return ReviewOutcome(
            stageOutcome: .completed(targetState: .awaitingAttribution, metadataJSON: encode(meta)),
            telemetry: ReviewDiarizationTelemetryPatch(
                diarizationSuggestionsCount: result.suggestions.count,
                diarizationReviewCostUSD: result.cost.costUSD,
                diarizationReviewModel: result.cost.modelID,
            ),
        )
    }

    private static func meta(modelID: String, skipped: Bool) -> ReviewDiarizationMeta {
        ReviewDiarizationMeta(modelID: modelID, inputTokens: 0, outputTokens: 0, costUSD: 0, suggestionsCount: 0, reviewSkipped: skipped)
    }

    private static func writeFailureStub(meetingID: MeetingID, settings: ReviewDiarizationSettings, error: ReviewDiarizationStageError) -> ReviewOutcome {
        writeStub(meetingID: meetingID, modelID: settings.modelID, meta: meta(modelID: settings.modelID, skipped: true), failure: error)
    }

    /// The empty result attribution reads when there is nothing to show. It
    /// carries `modelID` so the file says which configuration produced it.
    private static func writeStub(meetingID: MeetingID, modelID: String, meta: ReviewDiarizationMeta, failure: ReviewDiarizationStageError?) -> ReviewOutcome {
        let stub = AIReviewerResult<DiarizationSuggestion>(
            suggestions: [],
            cost: AIReviewerCost(inputTokens: 0, outputTokens: 0, costUSD: 0, modelID: modelID),
            reviewedSegmentCount: 0,
        )
        do {
            try CacheArtifactWriter.write(stub, for: meetingID, named: suggestionsArtifactName, schemaVersion: AIReviewerResult<DiarizationSuggestion>.currentSchemaVersion)
        } catch {
            return writeFailed()
        }
        let telemetry = ReviewDiarizationTelemetryPatch(diarizationSuggestionsCount: 0, diarizationReviewCostUSD: 0, diarizationReviewModel: modelID)
        guard let failure else {
            return ReviewOutcome(stageOutcome: .completed(targetState: .awaitingAttribution, metadataJSON: encode(meta)), telemetry: telemetry)
        }
        return ReviewOutcome(
            stageOutcome: .failed(targetState: .awaitingAttribution, errorClass: failure.errorClass, errorMessage: failure.errorMessage, metadataJSON: encode(meta)),
            telemetry: telemetry,
        )
    }

    /// `paid` is the reviewer's cost when the call succeeded and only the
    /// write failed: that spend happened and is recorded, with a count of 0
    /// because no suggestions reached disk. Without it nothing was spent, so
    /// there is nothing to record.
    private static func writeFailed(paid: AIReviewerCost? = nil) -> ReviewOutcome {
        let error = ReviewDiarizationStageError.suggestionsWriteFailed
        let telemetry = paid.map {
            ReviewDiarizationTelemetryPatch(diarizationSuggestionsCount: 0, diarizationReviewCostUSD: $0.costUSD, diarizationReviewModel: $0.modelID)
        }
        return ReviewOutcome(
            stageOutcome: .failed(targetState: .awaitingAttribution, errorClass: error.errorClass, errorMessage: error.errorMessage),
            telemetry: telemetry,
        )
    }

    private static func readInput(for meetingID: MeetingID) throws -> DiarizationReviewInput {
        let directory = try CacheArtifactWriter.cacheDirectory(for: meetingID)
        let decoder = JSONDecoder()
        let transcript = try decoder.decode(CanonicalTranscript.self, from: Data(contentsOf: directory.appendingPathComponent(transcriptArtifactName)))
        let diarization = try decoder.decode(DiarizationArtifact.self, from: Data(contentsOf: directory.appendingPathComponent(diarizationArtifactName)))
        return DiarizationReviewInput(transcript: transcript, diarization: diarization)
    }

    // MARK: - Telemetry and metadata

    /// Best-effort: the review is already on disk, and a telemetry failure
    /// must not turn it into a failed stage.
    private static func recordTelemetry(for result: ReviewOutcome, meetingID: MeetingID, recorder: TelemetryRecorder) async {
        guard let patch = result.telemetry else { return }
        do {
            try await recorder.record(meetingID: meetingID, patch: patch)
        } catch {
            log.warn("recording review telemetry failed", ["error": .publicSafe(String(reflecting: type(of: error)))])
        }
    }

    /// Encodes `ReviewDiarizationMeta` directly, not wrapped in
    /// `StageMetadata`, whose enum-keyed encoding would nest the payload under
    /// a `review_diarization` key. A failure degrades to `{}` because `work`
    /// must not crash on the row that records it.
    private static func encode(_ meta: ReviewDiarizationMeta) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(meta), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
