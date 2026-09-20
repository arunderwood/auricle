import Core
import Orchestrator
import State
import SummarizerInterface
import Telemetry

extension SummarizeStage {
    private static let postWriteLog = Log(category: "summarize-stage")

    /// The paid call has succeeded and its result is on disk. Nothing here may
    /// fail the stage: `summarization_failed` would have a retry pay for the
    /// same summary again.
    static func recordAfterSummaryWritten(
        for meetingID: MeetingID,
        outcome: SummarizerOrchestrator.Outcome,
        config: SummarizerConfig,
        match: CalendarEnrichment.Match?,
        promptSetHash: String?,
        stateStore: StateStore,
        telemetryRecorder: TelemetryRecorder,
    ) async {
        CostCeiling.warnIfExceeded(costUSD: outcome.summary.cost.costUSD, ceilingUSD: config.costCeilingUSD)

        if let match {
            await bestEffort("refresh_meeting_row") {
                try await refreshMeetingRow(for: meetingID, with: match, in: stateStore)
            }
        }

        await bestEffort("record_telemetry") {
            try await telemetryRecorder.record(
                meetingID: meetingID,
                patch: SummarizeTelemetryPatch(
                    quoteValidationDropCount: outcome.summary.quoteValidationDropCount,
                    summarizationPath: "claude_api",
                    summarizationModel: config.modelIdentifier,
                    summarizationEffortBudget: config.effortLevel.rawValue,
                    costUSD: outcome.summary.cost.costUSD,
                    summarizationPromptSetHash: promptSetHash,
                    groundingMethod: outcome.summary.groundingMethod.rawValue,
                ),
            )
        }
    }

    /// Logs a failure of a step that follows the summary write and carries on.
    /// Only the step name and the error's type name are logged, since a
    /// database error can embed a path or a value.
    private static func bestEffort(_ step: String, _ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            postWriteLog.warn("post-summary step failed", ["step": .publicSafe(step), "error": .publicSafe(String(reflecting: type(of: error)))])
        }
    }

    /// Writes only the two calendar columns. A whole-row write would put back
    /// the `state` the stage read before `StageRunner` moved it, and any column
    /// another writer changed while the summarizer ran. A row that has vanished
    /// is left for `StageRunner`'s own completion write to report.
    private static func refreshMeetingRow(for meetingID: MeetingID, with match: CalendarEnrichment.Match, in stateStore: StateStore) async throws {
        do {
            try await stateStore.setCalendarMatch(meetingID: meetingID.rawValue, title: match.title, calendarEventID: match.eventID)
        } catch StateStoreError.meetingNotFound {
            return
        }
    }
}
