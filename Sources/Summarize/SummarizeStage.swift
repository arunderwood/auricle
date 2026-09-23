import CalendarInterface
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
/// Calendar enrichment is an optional sub-step: a `CalendarSource` that
/// returns an event supplies the note's title and attendees and the prompt's
/// attendee names; no source, no match, a blank title or any error from the
/// source leaves the unenriched variant of the artifact and never fails the
/// stage. Either way `calendar.json` records which happened. The glossary the
/// caller injects is the full vault glossary; the stage scopes it to the
/// meeting itself before the summarizer sees it.
public enum SummarizeStage {
    static let summaryArtifactName = "summary.json"
    static let summarySchemaVersion = 1
    private static let calendarArtifactName = "calendar.json"
    private static let calendarSchemaVersion = 1
    static let transcriptArtifactName = "transcript.json"
    private static let log = Log(category: "summarize-stage")

    /// Completes into `persisting`: the summary is written and persist is
    /// pending or in flight. A state distinct from the active `summarizing`
    /// keeps a finished summarize out of the summarize stale-detection sweep
    /// and out of crash recovery's summarize re-dispatch, which would pay for
    /// the summary again.
    ///
    /// `glossary` is the full, unscoped vault glossary. The summarizer is
    /// given the part of it this meeting's attendees and transcript touch, and
    /// that part is written to the meeting's `glossary.json`.
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
        calendarSource: (any CalendarSource)? = nil,
        publishAnyway: Bool = false,
        selfWikilink: String? = nil,
    ) async throws -> StageRunner.StageOutcome {
        try await run(
            meetingID: meetingID,
            stateStore: stateStore,
            stageRunner: stageRunner,
            telemetryRecorder: telemetryRecorder,
            orchestrator: orchestrator,
            glossary: glossary,
            config: config,
            timeZone: timeZone,
            calendarSource: calendarSource,
            publishAnyway: publishAnyway,
            selfWikilink: selfWikilink,
            promptSetHash: bundledPromptSetHash,
        )
    }

    /// The public `run` with the prompt-set hash resolution injectable, so a
    /// test can make it throw and prove the stage stops before the summarizer
    /// call.
    static func run(
        meetingID: MeetingID,
        stateStore: StateStore,
        stageRunner: StageRunner,
        telemetryRecorder: TelemetryRecorder,
        orchestrator: SummarizerOrchestrator,
        glossary: Glossary,
        config: SummarizerConfig,
        timeZone: TimeZone = .current,
        calendarSource: (any CalendarSource)? = nil,
        publishAnyway: Bool = false,
        selfWikilink: String? = nil,
        promptSetHash: @escaping @Sendable (SummarizationMode) throws -> String = bundledPromptSetHash,
    ) async throws -> StageRunner.StageOutcome {
        guard let meeting = try await stateStore.fetchMeeting(id: meetingID.rawValue) else {
            throw StateStoreError.meetingNotFound(id: meetingID.rawValue)
        }
        let captureStartedAt = meeting.captureStartedAt
        return try await stageRunner.run(stage: .summarize, meetingID: meetingID, activeState: .summarizing) {
            do {
                return try await summarize(
                    meetingID: meetingID,
                    context: RunContext(
                        captureStartedAt: captureStartedAt,
                        timeZone: timeZone,
                        calendarSource: calendarSource,
                        publishAnyway: publishAnyway,
                        selfWikilink: selfWikilink,
                        promptSetHash: promptSetHash,
                    ),
                    stateStore: stateStore,
                    telemetryRecorder: telemetryRecorder,
                    orchestrator: orchestrator,
                    glossary: glossary,
                    config: config,
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

    /// The process exit code for `__internal-stage summarize`:
    /// `WorkerExitCode.success` on success, `stateError` (Decision 1.5) on any
    /// failure.
    public static func exitCode(for outcome: StageRunner.StageOutcome) -> Int32 {
        switch outcome {
        case .completed: WorkerExitCode.success
        case .failed: WorkerExitCode.stateError
        }
    }

    /// What `summarize` reads besides the meeting id, the collaborators and the
    /// summarizer inputs, bundled to keep its parameter list short.
    private struct RunContext: Sendable {
        let captureStartedAt: String?
        let timeZone: TimeZone
        let calendarSource: (any CalendarSource)?
        /// A failure after the calendar step leaves a stub summary for persist
        /// instead of failing the stage.
        let publishAnyway: Bool
        /// The configured `self.wikilink`; `nil` leaves the calendar's self
        /// identity, if any, to supply the note's self link.
        let selfWikilink: String?
        let promptSetHash: @Sendable (SummarizationMode) throws -> String
    }

    /// `promptDir: nil` is what both strategies pass to the prompt builder.
    @Sendable
    private static func bundledPromptSetHash(_ mode: SummarizationMode) throws -> String {
        try SummarizationPromptBuilder.promptSetHash(mode: mode, promptDir: nil)
    }

    // MARK: - Stage body

    /// Everything that can fail cheaply — reading and validating the inputs,
    /// and building the transcript segments — happens before the calendar
    /// lookup and the summarizer call, so a bad input never costs either.
    private static func summarize(
        meetingID: MeetingID,
        context: RunContext,
        stateStore: StateStore,
        telemetryRecorder: TelemetryRecorder,
        orchestrator: SummarizerOrchestrator,
        glossary: Glossary,
        config: SummarizerConfig,
    ) async throws -> StageRunner.StageOutcome {
        let inputs = try readInputs(for: meetingID, captureStartedAt: context.captureStartedAt)
        let (transcript, speakers, transcriptBytes, segments) = (inputs.transcript, inputs.speakers, inputs.transcriptBytes, inputs.segments)
        let captureStartedAtDate = inputs.captureStartedAt

        let promptSetHashes = try resolvePromptSetHashes(using: context.promptSetHash)

        let enrichment = try await CalendarEnrichment.resolve(using: context.calendarSource, at: captureStartedAtDate)
        writeCalendarArtifact(enrichment.artifact, for: meetingID)

        let scopedGlossary = scopeAndRecordGlossary(glossary, transcript: transcript, speakers: speakers, for: meetingID)

        // The stage owns the attendee names: whatever the caller put on the
        // config would disagree with the note's attendees.
        let enrichedConfig = config.withAttendeeNames(enrichment.match?.attendeeNames ?? [])
        let title = UnenrichedMeetingTitle.title(captureStartedAt: captureStartedAtDate, in: context.timeZone)
        let needsAttribution = inputs.needsAttribution

        let outcome: SummarizerOrchestrator.Outcome
        let artifact: SummaryArtifact
        do {
            outcome = try await orchestrator.summarize(transcript: transcript, glossary: scopedGlossary, config: enrichedConfig)
            artifact = try SummaryArtifactMapper.artifact(
                title: title,
                match: enrichment.match,
                configuredSelfWikilink: context.selfWikilink,
                grounded: outcome.summary,
                transcriptSegments: segments,
                needsAttribution: needsAttribution,
                transcriptBytes: transcriptBytes,
            )
        } catch where context.publishAnyway && !Task.isCancelled && !(error is CancellationError) {
            return try completeWithStub(
                after: error,
                for: meetingID,
                stub: SummaryArtifactMapper.stubArtifact(
                    title: title,
                    match: enrichment.match,
                    configuredSelfWikilink: context.selfWikilink,
                    transcriptSegments: segments,
                    needsAttribution: needsAttribution,
                ),
            )
        }
        try writeSummary(artifact, for: meetingID)

        await recordAfterSummaryWritten(
            for: meetingID,
            outcome: outcome,
            config: config,
            match: enrichment.match,
            promptSetHash: promptSetHashes[outcome.summary.groundingMethod.summarizationMode],
            stateStore: stateStore,
            telemetryRecorder: telemetryRecorder,
        )

        return .completed(
            targetState: .persisting,
            metadataJSON: encodeMetadataJSON(outcome: outcome, config: config),
        )
    }

    // MARK: - Calendar

    /// A cache artifact the note does not depend on, so a write that fails is
    /// logged and dropped rather than costing the meeting its summary. Only
    /// the error's type name is logged: `CacheArtifactWriter.WriteError`
    /// carries paths.
    private static func writeCalendarArtifact(_ artifact: CalendarArtifact, for meetingID: MeetingID) {
        do {
            try CacheArtifactWriter.write(artifact, for: meetingID, named: calendarArtifactName, schemaVersion: calendarSchemaVersion)
        } catch {
            log.warn("calendar.json write failed", ["error": .publicSafe(String(reflecting: type(of: error)))])
        }
    }

    /// One hash per mode, computed before the summarizer call because which
    /// strategy answers is not known until it has been paid for: a prompt
    /// file that cannot be resolved must fail the stage here rather than
    /// after the spend. `promptDir: nil` is what both strategies pass to the
    /// prompt builder, so each hash is the one that strategy's own prompt
    /// carries; a strategy that starts honoring a prompt directory needs the
    /// same directory passed here.
    private static func resolvePromptSetHashes(
        using resolve: @Sendable (SummarizationMode) throws -> String,
    ) throws -> [SummarizationMode: String] {
        var hashes: [SummarizationMode: String] = [:]
        for mode in SummarizationMode.allCases {
            do {
                hashes[mode] = try resolve(mode)
            } catch {
                throw SummarizeStageError.promptSetUnavailable
            }
        }
        return hashes
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
            costCeilingUSD: config.costCeilingUSD,
            costCeilingExceeded: CostCeiling.isExceeded(costUSD: cost.costUSD, ceilingUSD: config.costCeilingUSD),
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

    /// Only a case name, a type name or a fixed sentence is ever recorded,
    /// never an error's own message: a foreign error can embed a path, a response body or transcript
    /// text, and `error_message` is persisted in `stage_events`.
    static func failure(for error: Error) -> (errorClass: String, message: String) {
        switch error {
        case let stageError as SummarizeStageError:
            (stageError.errorClass, String(describing: stageError))
        case let summarizerError as SummarizerError:
            (summarizerError.stageErrorClass, summarizerError.stageErrorMessage)
        default:
            ("summarize_unexpected_error", String(reflecting: type(of: error)))
        }
    }
}

private extension GroundingMethod {
    /// The prompt mode a strategy answering with this method built its prompt
    /// from. Exhaustive rather than a `rawValue` round trip, so a new grounding
    /// method cannot compile until it names the prompt files it uses.
    var summarizationMode: SummarizationMode {
        switch self {
        case .citations: .citations
        case .substring: .substring
        }
    }
}
