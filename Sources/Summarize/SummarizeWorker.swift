import CalendarInterface
import Core
import Foundation
import Orchestrator
import State
import SummarizerInterface
import Telemetry

/// What `__internal-stage summarize` does once its dependencies are built: run
/// the stage and map every result to a process exit. It lives here rather than
/// in the CLI target because nothing under `App/` is reached by `swift test`,
/// and the mapping is the part a regression would otherwise slip through (see
/// `TranscribeWorker`).
public enum SummarizeWorker {
    /// The exit is `SummarizeStage.exitCode` for a stage that ran, 3 for an
    /// unknown meeting (the stage throws before it records anything), and 2
    /// when the state store fails underneath the stage. The runner and the
    /// telemetry recorder are built over `stateStore`, since the worker is the
    /// composition point that owns which store a stage writes to.
    public static func run(
        meetingID: MeetingID,
        stateStore: StateStore,
        orchestrator: SummarizerOrchestrator,
        glossary: Glossary,
        config: SummarizerConfig,
        calendarSource: (any CalendarSource)?,
    ) async -> WorkerExitStatus {
        await exitStatus {
            try await SummarizeStage.run(
                meetingID: meetingID,
                stateStore: stateStore,
                stageRunner: StageRunner(stateStore: stateStore, stageEventLogger: StageEventLogger(stateStore: stateStore)),
                telemetryRecorder: TelemetryRecorder(stateStore: stateStore),
                orchestrator: orchestrator,
                glossary: glossary,
                config: config,
                calendarSource: calendarSource,
            )
        }
    }

    /// The error-to-exit mapping, apart from what runs the stage. The message
    /// is a fixed sentence or a type name, never an error's own text: the
    /// caller writes it to stderr, and a foreign error can embed a path or
    /// transcript text.
    static func exitStatus(from runStage: () async throws -> StageRunner.StageOutcome) async -> WorkerExitStatus {
        do {
            let outcome = try await runStage()
            return WorkerExitStatus(code: SummarizeStage.exitCode(for: outcome))
        } catch StateStoreError.meetingNotFound {
            return WorkerExitStatus(code: WorkerExitCode.meetingNotFound, message: "no meeting has the given ID.")
        } catch {
            return WorkerExitStatus(
                code: WorkerExitCode.stateError,
                message: "summarize could not record its progress (\(String(reflecting: type(of: error)))).",
            )
        }
    }
}
