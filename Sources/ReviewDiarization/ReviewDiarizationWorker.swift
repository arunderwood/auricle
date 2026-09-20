import AIReviewerInterface
import Core
import Foundation
import Orchestrator
import State
import Telemetry

/// What `__internal-stage review-diarization` does once its dependencies are
/// built: the meeting lookup, the stage, and the mapping of every result to a
/// process exit. It lives here rather than in the CLI target because nothing
/// under `App/` is reached by `swift test`.
public enum ReviewDiarizationWorker {
    public typealias Exit = WorkerExitStatus

    /// The exit code is `ReviewDiarizationStage.exitCode` for a stage that
    /// ran, 3 for an unknown meeting, and 2 when the state store fails
    /// underneath the stage.
    public static func run(
        meetingID: MeetingID,
        stateStore: StateStore,
        stageRunner: StageRunner,
        reviewer: any DiarizationReviewerStrategy,
        settings: ReviewDiarizationSettings,
    ) async -> Exit {
        do {
            let outcome = try await ReviewDiarizationStage.run(
                meetingID: meetingID,
                stateStore: stateStore,
                stageRunner: stageRunner,
                telemetryRecorder: TelemetryRecorder(stateStore: stateStore),
                reviewer: reviewer,
                settings: settings,
            )
            return Exit(code: ReviewDiarizationStage.exitCode(for: outcome))
        } catch StateStoreError.meetingNotFound {
            return Exit(code: WorkerExitCode.meetingNotFound, message: "no meeting has the given ID.")
        } catch {
            return Exit(code: WorkerExitCode.stateError, message: "could not record its progress (\(String(reflecting: type(of: error)))).")
        }
    }
}
