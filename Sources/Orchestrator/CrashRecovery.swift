import Core
import State

/// On-launch reconciliation (FR62, NFR-R5, NFR-R6): a meeting left sitting
/// in an active "_ing" state is the canonical signal that its subprocess
/// crashed between Txn A and Txn B (AR-PIPE-3) — nothing else moves
/// `meetings.state` there and then stops. `reconcile()` runs the AC's
/// literal query, re-dispatching the states with an automatic subprocess
/// re-run and only logging `attributing`, `persisting` and `published` —
/// `attributing` is user-paced (nothing to automatically re-invoke), and
/// `persisting` and `published` are waiting on `persist` and `notify`, which
/// run in-process per AR-PIPE-1 rather than as subprocesses. No in-process
/// API exists for crash recovery to call into. The stale-detection sweep
/// moves an orphaned `persisting` meeting to `persist_failed`, which
/// `auricle run <id>` resumes; a `persisting` meeting must never be
/// dispatched as `summarize`, because that would repeat a paid summarization.
public struct CrashRecovery: Sendable {
    public enum Outcome: Sendable, Equatable {
        /// The worker was launched, not that it succeeded: its exit status
        /// arrives later through `onWorkerExit`.
        case redispatched(MeetingID, PipelineStage)
        case loggedOnly(MeetingID, PipelineState)
    }

    /// `SELECT id FROM meetings WHERE state IN (...)` from the AC, as a
    /// `Set` so membership is an O(1) filter over `StateStore.fetchPending()`'s
    /// broader "every non-terminal meeting" result.
    private static let reconcilableActiveStates: Set<PipelineState> = [
        .transcribing, .reviewingDiarization, .attributing, .summarizing, .persisting, .published,
    ]

    /// Active states with no automatic subprocess re-dispatch: only
    /// detected and logged.
    private static let logOnlyActiveStates: Set<PipelineState> = [.attributing, .persisting, .published]

    private static let log = Log(category: "orchestrator")

    private let stateStore: StateStore
    private let dispatcher: SubprocessDispatcher
    private let onWorkerExit: @Sendable (WorkerExit) -> Void

    /// `onWorkerExit` is called once per re-dispatched worker, on a queue
    /// Foundation chooses, so a fast worker can report before `reconcile()` has
    /// returned. Left `nil` it warns about a non-zero status: a worker that
    /// fails at argument parsing would otherwise look the same as one that
    /// finished.
    public init(
        stateStore: StateStore,
        dispatcher: SubprocessDispatcher,
        onWorkerExit: (@Sendable (WorkerExit) -> Void)? = nil,
    ) {
        self.init(stateStore: stateStore, dispatcher: dispatcher, onWorkerExit: onWorkerExit, log: Self.log)
    }

    /// `log` is where the default observer warns; a test passes its own to see
    /// what the default does.
    init(
        stateStore: StateStore,
        dispatcher: SubprocessDispatcher,
        onWorkerExit: (@Sendable (WorkerExit) -> Void)?,
        log: Log,
    ) {
        self.stateStore = stateStore
        self.dispatcher = dispatcher
        self.onWorkerExit = onWorkerExit ?? { Self.warnOnNonzeroExit($0, to: log) }
    }

    /// Only the stage, the meeting id and the status are logged: the worker's
    /// stderr is not captured, and a status is all this can know.
    static func warnOnNonzeroExit(_ exit: WorkerExit, to log: Log) {
        guard exit.status != 0 else { return }
        log.warn("a re-dispatched worker exited with a non-zero status", [
            "meetingID": .publicSafe(exit.meetingID),
            "stage": .publicSafe(exit.stage.rawValue),
            "status": .publicSafe(exit.status),
        ])
    }

    @discardableResult
    public func reconcile() async throws -> [Outcome] {
        let candidates = try await stateStore.fetchPending()
        var outcomes: [Outcome] = []

        for meeting in candidates {
            guard
                let state = PipelineState(rawValue: meeting.state),
                Self.reconcilableActiveStates.contains(state)
            else { continue }

            guard let meetingID = MeetingID(ulid: meeting.id) else {
                Self.log.warn("crash recovery found a candidate meeting whose id failed ULID validation; skipping", [
                    "rawID": .publicSafe(meeting.id),
                    "state": .publicSafe(state.rawValue),
                ])
                continue
            }

            if Self.logOnlyActiveStates.contains(state) {
                Self.log.info("crash recovery found meeting in an active state with no automatic subprocess re-dispatch", [
                    "meetingID": .publicSafe(meetingID),
                    "state": .publicSafe(state.rawValue),
                ])
                outcomes.append(.loggedOnly(meetingID, state))
                continue
            }

            guard let stage = ActiveStageInFlight.stage(for: state) else { continue }

            do {
                try dispatcher.dispatch(stage: stage, meetingID: meetingID, onExit: onWorkerExit)
                Self.log.info("crash recovery re-dispatched stuck stage", [
                    "meetingID": .publicSafe(meetingID),
                    "stage": .publicSafe(stage.rawValue),
                ])
                outcomes.append(.redispatched(meetingID, stage))
            } catch {
                Self.log.warn("crash recovery failed to re-dispatch a stuck stage; continuing with remaining candidates", [
                    "meetingID": .publicSafe(meetingID),
                    "stage": .publicSafe(stage.rawValue),
                ])
            }
        }
        return outcomes
    }
}
