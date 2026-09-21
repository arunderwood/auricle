import Attribute
import Core
import Foundation
import Notifications
import Orchestrator
import Persist
import State
import Telemetry
import Transcribe

/// How an `auricle run` ended, for the thin verb to print and exit with.
public struct RunResult: Sendable, Equatable {
    /// `0`, a worker's own exit code, or one of `WorkerExitCode`'s. `130` is a
    /// run interrupted by SIGINT.
    public let exitCode: Int32
    /// One line for stderr, or `nil`.
    public let message: String?
    /// Lines for stdout. Empty unless the run has something to say the
    /// notifier did not.
    public let lines: [String]

    public init(exitCode: Int32, message: String? = nil, lines: [String] = []) {
        self.exitCode = exitCode
        self.message = message
        self.lines = lines
    }

    public static let interrupted: Int32 = 130
}

/// Drives a meeting through the stages of a `RunPlan` (AR-PIPE-1):
/// `transcribe`, `review-diarization` and `summarize` as `__internal-stage`
/// subprocesses, `attribute`, `persist` and `notify` in this process.
///
/// It never writes `meetings.verified_at`: verification is a human act. It
/// never touches a retention timer, so a re-attribution leaves the armed one
/// alone. Persist is given no re-publish flag; it derives one from the note
/// the meeting already has.
///
/// Cancellation is honored between stages. An in-process stage is not
/// interrupted, and a subprocess stage is terminated by its launcher.
public struct PipelineRunner: Sendable {
    /// Collaborators and configuration, bundled to keep the initializer short.
    public struct Environment: Sendable {
        public let stateStore: StateStore
        public let launcher: any StageWorkerLauncher
        public let notifier: any Notifier
        /// `nil` when `vault_path` is unset; a run that reaches persist then
        /// refuses before it starts.
        public let vaultPath: URL?
        public let meetingsSubdir: String
        public let glossary: Glossary
        public let clock: PersistStage.TimeSource

        public init(
            stateStore: StateStore,
            launcher: any StageWorkerLauncher,
            notifier: any Notifier,
            vaultPath: URL?,
            meetingsSubdir: String,
            glossary: Glossary = Glossary(),
            clock: PersistStage.TimeSource = PersistStage.TimeSource(),
        ) {
            self.stateStore = stateStore
            self.launcher = launcher
            self.notifier = notifier
            self.vaultPath = vaultPath
            self.meetingsSubdir = meetingsSubdir
            self.glossary = glossary
            self.clock = clock
        }
    }

    static let cancelledErrorClass = "cancelled_by_user"
    private static let log = Log(category: "pipeline-runner")

    private let environment: Environment
    private let stageRunner: StageRunner
    private let eventLogger: StageEventLogger
    private let telemetryRecorder: TelemetryRecorder

    public init(environment: Environment) {
        self.environment = environment
        eventLogger = StageEventLogger(stateStore: environment.stateStore)
        stageRunner = StageRunner(stateStore: environment.stateStore, stageEventLogger: eventLogger)
        telemetryRecorder = TelemetryRecorder(stateStore: environment.stateStore)
    }

    public func run(meetingID: MeetingID, options: RunOptions) async -> RunResult {
        let meeting: Meeting
        do {
            guard let found = try await environment.stateStore.fetchMeeting(id: meetingID.rawValue) else {
                return RunResult(exitCode: WorkerExitCode.meetingNotFound, message: "no meeting has the given ID.")
            }
            meeting = found
        } catch {
            return stateFailure(error)
        }
        guard let state = PipelineState(rawValue: meeting.state) else {
            return RunResult(exitCode: WorkerExitCode.stateError, message: "the meeting is in an unrecognized state.")
        }

        let plan: RunPlan
        switch prepare(options: options, state: state) {
        case let .ready(prepared): plan = prepared
        case let .stop(result): return result
        }

        for stage in plan.stages {
            if Task.isCancelled {
                return await interrupted(meetingID)
            }
            do {
                if let failure = try await execute(stage, meetingID: meetingID, plan: plan, options: options) {
                    return failure
                }
            } catch is CancellationError {
                return await interrupted(meetingID)
            } catch {
                return stateFailure(error)
            }
        }
        return await finished(meetingID)
    }

    private enum Preparation {
        case ready(RunPlan)
        case stop(RunResult)
    }

    /// The plan, or the result that ends the run before it starts. Nothing is
    /// spent on a run that cannot reach persist.
    private func prepare(options: RunOptions, state: PipelineState) -> Preparation {
        let plan: RunPlan
        switch RunPlan.make(options: options, state: state) {
        case let .success(made): plan = made
        case let .failure(refusal): return .stop(RunResult(exitCode: WorkerExitCode.callerError, message: refusal.message))
        }
        guard !plan.stages.isEmpty else {
            return .stop(RunResult(exitCode: WorkerExitCode.success, message: "nothing to run from state \(state.rawValue)."))
        }
        if plan.stages.contains(.persist), environment.vaultPath == nil {
            return .stop(RunResult(exitCode: WorkerExitCode.callerError, message: "vault_path is not set in ~/.auricle/config.toml."))
        }
        return .ready(plan)
    }

    // MARK: - Stages

    /// `nil` when the stage completed and the run should continue.
    ///
    /// The state is read again before every stage, not only before the first:
    /// a stage that failed to leave the meeting where the next one starts must
    /// stop the run, not run the next stage against the wrong state. An
    /// in-process stage carries what it read into its `started` write, which
    /// then lands only if the meeting is still there. A subprocess stage runs
    /// in another process, so its check is the read alone.
    private func execute(_ stage: RunStage, meetingID: MeetingID, plan: RunPlan, options: RunOptions) async throws -> RunResult? {
        guard let meeting = try await environment.stateStore.fetchMeeting(id: meetingID.rawValue) else {
            return RunResult(exitCode: WorkerExitCode.meetingNotFound, message: "no meeting has the given ID.")
        }
        guard let state = PipelineState(rawValue: meeting.state) else {
            return RunResult(exitCode: WorkerExitCode.stateError, message: "the meeting is in an unrecognized state.")
        }
        guard stage.entryStates.contains(state) else {
            return RunResult(exitCode: WorkerExitCode.callerError, message: RunRefusal.cannotStart(stage: stage, state: state).message)
        }
        switch stage.execution {
        case .subprocess:
            return try await runWorker(stage, meetingID: meetingID, plan: plan)
        case .inProcess:
            switch stage {
            case .attribute: return try await runAttribute(meetingID: meetingID, plan: plan, options: options)
            case .persist: return try await runPersist(meetingID: meetingID, expectedState: state)
            default: return try await runNotify(meetingID: meetingID, meeting: meeting, expectedState: state)
            }
        }
    }

    /// `transcribe` follows `TranscribeRetryPolicy`: one retry in a fresh
    /// process after a failure a fresh process might not repeat.
    private func runWorker(_ stage: RunStage, meetingID: MeetingID, plan: RunPlan) async throws -> RunResult? {
        let launcher = environment.launcher
        let launch: @Sendable () async throws -> TranscribeRetryPolicy.Termination = {
            try await launcher.run(stage: stage.pipelineStage, meetingID: meetingID, publishAnyway: plan.publishAnyway)
        }
        let termination: TranscribeRetryPolicy.Termination
        if stage == .transcribe {
            let outcome = try await TranscribeRetryPolicy.run { attempt in
                if attempt > 1 {
                    await recordRetry(meetingID: meetingID, stage: stage.pipelineStage)
                }
                return try await launch()
            }
            switch outcome {
            case .succeeded: return nil
            case let .failed(_, ended), let .exhausted(_, ended): termination = ended
            }
        } else {
            termination = try await launch()
            if termination == .exited(0) {
                return nil
            }
        }
        let code = Self.exitCode(for: termination)
        return RunResult(exitCode: code, message: "\(stage.rawValue) failed (exit \(code)).")
    }

    /// A signal is reported the way a shell does, as 128 plus its number.
    private static func exitCode(for termination: TranscribeRetryPolicy.Termination) -> Int32 {
        switch termination {
        case let .exited(status): status
        case let .signaled(signal): 128 + signal
        }
    }

    private func runAttribute(meetingID: MeetingID, plan: RunPlan, options: RunOptions) async throws -> RunResult? {
        let mode: AttributionStage.Mode = plan.publishAnyway ? .publishAnyway : .batch(speakers: nil)
        do {
            let outcome = try await AttributionStage.run(
                meetingID: meetingID,
                mode: mode,
                stateStore: environment.stateStore,
                stageRunner: stageRunner,
                telemetryRecorder: telemetryRecorder,
                glossary: environment.glossary,
                reattribute: options.reattribute || options.force,
            )
            guard AttributionStage.exitCode(for: outcome) == WorkerExitCode.success else {
                return RunResult(exitCode: WorkerExitCode.stateError, message: "attribute could not record its progress.")
            }
            return nil
        } catch AttributionStageError.noSpeakerMapping {
            return RunResult(
                exitCode: WorkerExitCode.callerError,
                message: "no speaker mapping. Run `auricle attribute \(meetingID.rawValue) --speakers \"1=Name\"`, or re-run with --publish-anyway.",
            )
        } catch let error as AttributionStageError {
            let code = error == .attributionWriteFailed ? WorkerExitCode.stateError : WorkerExitCode.callerError
            return RunResult(exitCode: code, message: error.userMessage)
        }
    }

    private func runPersist(meetingID: MeetingID, expectedState: PipelineState) async throws -> RunResult? {
        guard let vaultPath = environment.vaultPath else {
            return RunResult(exitCode: WorkerExitCode.callerError, message: "vault_path is not set in ~/.auricle/config.toml.")
        }
        let outcome = try await PersistStage.run(
            meetingID: meetingID,
            cacheDirectory: CacheArtifactWriter.cacheDirectory(for: meetingID),
            vaultPath: vaultPath,
            meetingsSubdir: environment.meetingsSubdir,
            stateStore: environment.stateStore,
            stageRunner: stageRunner,
            clock: environment.clock,
            expectedState: expectedState,
        )
        guard case let .failed(_, errorClass, _, _) = outcome else { return nil }
        return RunResult(exitCode: WorkerExitCode.stateError, message: "persist failed (\(errorClass)); re-run to retry it.")
    }

    /// A `published_partial` meeting is not notified: it awaits a summary, not
    /// verification, so the note path is printed instead.
    private func runNotify(meetingID: MeetingID, meeting: Meeting, expectedState: PipelineState) async throws -> RunResult? {
        if meeting.state == PipelineState.publishedPartial.rawValue {
            return nil
        }
        _ = try await NotifyStage.run(
            meetingID: meetingID,
            title: meeting.title ?? "Meeting",
            notifier: environment.notifier,
            stateStore: environment.stateStore,
            stageRunner: stageRunner,
            expectedState: expectedState,
        )
        return nil
    }
}

// MARK: - Ending

extension PipelineRunner {
    private func finished(_ meetingID: MeetingID) async -> RunResult {
        guard
            let meeting = try? await environment.stateStore.fetchMeeting(id: meetingID.rawValue),
            meeting.state == PipelineState.publishedPartial.rawValue,
            let notePath = meeting.vaultNotePath
        else {
            return RunResult(exitCode: WorkerExitCode.success)
        }
        return RunResult(
            exitCode: WorkerExitCode.success,
            message: "published without a summary; run `auricle run \(meetingID.rawValue)` to retry it.",
            lines: [notePath],
        )
    }

    /// Runs detached: the calling task is cancelled, and a cancelled task's
    /// database calls throw before they write. The meeting is failed only if
    /// it is still `summarizing`, so an interrupt that lands after summarize
    /// finished does not undo it.
    private func interrupted(_ meetingID: MeetingID) async -> RunResult {
        let store = environment.stateStore
        let logger = eventLogger
        await Task.detached {
            do {
                guard try await store.fetchMeeting(id: meetingID.rawValue)?.state == PipelineState.summarizing.rawValue else { return }
                try await logger.record(event: StageEventRecord(
                    meetingID: meetingID,
                    stage: .summarize,
                    kind: .failed,
                    occurredAt: ISO8601UTC.string(from: Date()),
                    targetState: .summarizationFailed,
                    errorMessage: "interrupted",
                    metadataJSON: "{\"error_class\":\"\(Self.cancelledErrorClass)\"}",
                    expectedState: .summarizing,
                ))
            } catch StateStoreError.staleWrite {
                Self.log.info("the meeting moved before the interrupt could fail it; leaving it")
            } catch {
                Self.log.warn("could not record the interrupt", ["error": .publicSafe(String(reflecting: type(of: error)))])
            }
        }.value
        return RunResult(exitCode: RunResult.interrupted, message: "interrupted.")
    }

    private func recordRetry(meetingID: MeetingID, stage: PipelineStage) async {
        do {
            try await eventLogger.record(event: StageEventRecord(
                meetingID: meetingID,
                stage: stage,
                kind: .retried,
                occurredAt: ISO8601UTC.string(from: Date()),
                metadataJSON: "{}",
            ))
        } catch {
            Self.log.warn("could not record the retry", ["error": .publicSafe(String(reflecting: type(of: error)))])
        }
    }

    private func stateFailure(_ error: Error) -> RunResult {
        if case StateStoreError.staleWrite = error {
            return RunResult(exitCode: WorkerExitCode.stateError, message: "the meeting changed state before the stage could start; nothing was written.")
        }
        return RunResult(
            exitCode: WorkerExitCode.stateError,
            message: "could not record its progress (\(String(reflecting: type(of: error)))).",
        )
    }
}
