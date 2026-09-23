import Core
import Foundation
import State
import Telemetry

/// The single wrapper for the two-transaction pattern (AR-PIPE-3): every
/// stage calls `run`, never `StateStore.recordStageTransition` directly —
/// nor does `StageRunner` itself; both `run` and `synthesizeFailure` write
/// `stage_events` through `StageEventLogger` (AR-PAT-4), which wraps the
/// same `StateStore` calls unchanged. Txn A
/// (`started` + `activeState`) commits before `work` runs; Txn B
/// (`completed`/`failed` + the outcome's own `targetState`) commits after.
/// If `work` throws, Txn B never runs — the meeting is left sitting in
/// `activeState`, architecturally identical to a subprocess crash between
/// the two transactions, and is exactly what `synthesizeFailure` (via the
/// stale-detection sweep) and `CrashRecovery` exist to reconcile later.
///
/// `run`'s Txn B is unguarded: a stage that finishes late still wins over a
/// sweep-synthesized failure. Txn A is guarded only when the caller passes
/// `expectedState`, the state it read before choosing to run the stage: a
/// caller that dispatches on an operator's request must not move a meeting
/// that has since left that state.
public actor StageRunner {
    private let stateStore: StateStore
    private let stageEventLogger: StageEventLogger
    private let now: @Sendable () -> Date
    let log: Log

    public init(
        stateStore: StateStore,
        stageEventLogger: StageEventLogger,
        now: @escaping @Sendable () -> Date = { Date() },
        log: Log = Log(category: "orchestrator"),
    ) {
        self.stateStore = stateStore
        self.stageEventLogger = stageEventLogger
        self.now = now
        self.log = log
    }

    public enum StageOutcome: Sendable {
        case completed(targetState: PipelineState, metadataJSON: String? = nil)
        case failed(targetState: PipelineState, errorClass: String, errorMessage: String? = nil, metadataJSON: String? = nil)

        public var targetState: PipelineState {
            switch self {
            case let .completed(targetState, _), let .failed(targetState, _, _, _):
                targetState
            }
        }
    }

    /// `run` refused a transition `PipelineTransitions` does not allow.
    public enum TransitionError: Error, Sendable, Equatable {
        /// `(stage, activeState)` has no table entry, so nothing was written.
        case unsupportedStage(stage: PipelineStage, activeState: PipelineState)
        /// The work returned an outcome targeting a state outside the pair's
        /// entry. Txn A had already committed; Txn B was not written, so the
        /// meeting is left in `activeState` as if the stage had crashed.
        case targetNotAllowed(stage: PipelineStage, activeState: PipelineState, targetState: PipelineState)
    }

    /// Why `synthesizeFailure` is transitioning a meeting out from under a
    /// stage that never called `run` again to close it out. `staleActiveState`
    /// is the only source today (the periodic sweep); a distinct case per
    /// future synthesis source keeps `stage_events.error_message` traceable
    /// to its cause without inventing a free-text convention per call site.
    public enum StaleFailureReason: Sendable, Equatable {
        case staleActiveState(budgetSeconds: Int)

        var errorMessage: String {
            switch self {
            case let .staleActiveState(budgetSeconds):
                "stale active state: exceeded \(budgetSeconds)s wall-clock budget"
            }
        }
    }

    public enum SynthesizeFailureError: Error, Sendable, Equatable {
        /// `synthesizeFailure` only knows the transition for the 4 budgeted
        /// active states (AR-FAIL-2); `attributing` has no budget and every
        /// other state is either not "_ing" or not reachable by the sweep.
        case noStaleTransition(activeState: PipelineState)
    }

    // MARK: - Stage execution

    public func run(
        stage: PipelineStage,
        meetingID: MeetingID,
        activeState: PipelineState,
        expectedState: PipelineState? = nil,
        work: @Sendable () async throws -> StageOutcome,
    ) async throws -> StageOutcome {
        // Capture's table entry describes the writes `StateStore.finishCapture`
        // makes; capture itself never runs through here, so it is refused
        // like a pair with no entry.
        guard stage != .capture, let allowedTargets = PipelineTransitions.allowedTargets(stage: stage, activeState: activeState) else {
            logRejectedTransition("stage has no transition table entry for its active state", meetingID: meetingID, stage: stage, activeState: activeState)
            throw TransitionError.unsupportedStage(stage: stage, activeState: activeState)
        }

        // `now()` is read exactly twice per run: here, and once after `work`.
        // The gap between them is `duration_ms`.
        let startedAt = now()
        try await stageEventLogger.record(event: StageEventRecord(
            meetingID: meetingID,
            stage: stage,
            kind: .started,
            occurredAt: ISO8601UTC.string(from: startedAt),
            targetState: activeState,
            metadataJSON: "{}",
            expectedState: expectedState,
        ))
        logTransition(meetingID: meetingID, stage: stage, kind: .started, state: activeState)

        let outcome = try await work()
        let finishedAt = now()

        try requireAllowed(outcome.targetState, in: allowedTargets, stage: stage, meetingID: meetingID, activeState: activeState)

        let occurredAt = ISO8601UTC.string(from: finishedAt)
        let durationMS = max(0, Int((finishedAt.timeIntervalSince(startedAt) * 1000).rounded()))

        switch outcome {
        case let .completed(targetState, metadataJSON):
            try await stageEventLogger.record(event: StageEventRecord(
                meetingID: meetingID,
                stage: stage,
                kind: .completed,
                occurredAt: occurredAt,
                targetState: targetState,
                durationMS: durationMS,
                metadataJSON: metadataJSON,
            ))
            logTransition(meetingID: meetingID, stage: stage, kind: .completed, state: targetState, durationMS: durationMS)
        case let .failed(targetState, errorClass, errorMessage, metadataJSON):
            try await stageEventLogger.record(event: StageEventRecord(
                meetingID: meetingID,
                stage: stage,
                kind: .failed,
                occurredAt: occurredAt,
                targetState: targetState,
                durationMS: durationMS,
                errorMessage: errorMessage,
                metadataJSON: buildFailedMetadataJSON(errorClass: errorClass, mergingInto: metadataJSON),
            ))
            logTransition(meetingID: meetingID, stage: stage, kind: .failed, state: targetState, durationMS: durationMS, errorClass: errorClass)
        }
        return outcome
    }

    /// The outcome's target must be in the pair's table entry. Txn A has
    /// already committed, so a rejection leaves the meeting in `activeState`
    /// as a crashed stage would, and the log line is the only trace of why.
    private func requireAllowed(
        _ targetState: PipelineState,
        in allowedTargets: Set<PipelineState>,
        stage: PipelineStage,
        meetingID: MeetingID,
        activeState: PipelineState,
    ) throws {
        guard allowedTargets.contains(targetState) else {
            logRejectedTransition(
                "stage returned an outcome outside its transition table entry; recording nothing",
                meetingID: meetingID,
                stage: stage,
                activeState: activeState,
                targetState: targetState,
            )
            throw TransitionError.targetNotAllowed(stage: stage, activeState: activeState, targetState: targetState)
        }
    }

    // MARK: - Stale-detection synthesis

    /// Per-state wall-clock stale-detection budgets, in seconds (AR-FAIL-2 /
    /// Decision 4.2, architecture.md:1061-1069): `transcribing` 2× NFR-P3
    /// (60s), `reviewingDiarization` 90s fixed, `summarizing` 2× NFR-P5
    /// (720s — architecture's own stated ≈12min figure), `persisting` 60s
    /// fixed, `published` 30s. `attributing` is intentionally absent —
    /// user-paced, no auto-failure.
    ///
    /// `persisting` is a fixed budget, not a multiple of a stage budget:
    /// persist writes one note file, whose NFR-P8 budget is 500 ms, so 60s is
    /// 120× the healthy case. That leaves room for a vault on a slow or
    /// syncing volume, yet a crashed persist surfaces as `persist_failed`
    /// within about a minute.
    public static let staleDetectionBudgetSeconds: [PipelineState: Int] = [
        .transcribing: 60,
        .reviewingDiarization: 90,
        .summarizing: 720,
        .persisting: 60,
        .published: 30,
    ]

    struct StaleTransition {
        let targetState: PipelineState
        let errorClass: String
    }

    /// The exact per-state table from the I/O matrix: `reviewingDiarization`
    /// and `published` are benign passthroughs (not `*_failed`);
    /// `transcribing`/`summarizing`/`persisting` are the general
    /// "stale → `*_failed`" case. `published`'s passthrough is a narrow,
    /// explicit carve-out of the AC's general rule, not this table
    /// forgetting to fail it —
    /// `published_partial` is a distinct, unrelated trigger (only
    /// `--publish-anyway` + no summarize output) and never fires for a stuck
    /// notify.
    static func staleTransition(for activeState: PipelineState) -> StaleTransition? {
        switch activeState {
        case .transcribing:
            StaleTransition(targetState: .transcriptionFailed, errorClass: "stale_active_state")
        case .reviewingDiarization:
            StaleTransition(targetState: .awaitingAttribution, errorClass: "ai_reviewer_timeout")
        case .summarizing:
            StaleTransition(targetState: .summarizationFailed, errorClass: "stale_active_state")
        case .persisting:
            StaleTransition(targetState: .persistFailed, errorClass: "stale_active_state")
        case .published:
            StaleTransition(targetState: .awaitingVerification, errorClass: "stale_active_state")
        default:
            nil
        }
    }

    /// Closes out a meeting stuck in `activeState` with the Txn-B-only write
    /// the I/O matrix specifies for that state: no fresh Txn A, because the
    /// original stage's own `run` call already wrote one — this only
    /// records the `failed` `stage_events` row (`error_class` folded into
    /// `metadata_json`, since the schema has no dedicated column — see
    /// architecture.md:1211) and moves `meetings.state` to the resolved
    /// target. Performs no cache-dir writes: `reviewingDiarization`'s
    /// `diarization_suggestions.json` stub is deferred to the story that
    /// implements the real `ReviewDiarization` stage.
    ///
    /// The write is conditional on the meeting still being in `activeState`,
    /// and, when `expectedUpdatedAt` is given, still carrying that `updated_at`.
    /// A caller that decided on a snapshot passes the `updated_at` it read:
    /// a stage that completes into its own active state leaves `state`
    /// unchanged, so the timestamp is what tells a finished stage from a
    /// running one. A lost race throws `StateStoreError.staleWrite` with
    /// nothing written.
    public func synthesizeFailure(
        meetingID: MeetingID,
        stage: PipelineStage,
        activeState: PipelineState,
        reason: StaleFailureReason,
        expectedUpdatedAt: String? = nil,
    ) async throws {
        guard let transition = Self.staleTransition(for: activeState) else {
            throw SynthesizeFailureError.noStaleTransition(activeState: activeState)
        }

        try await stageEventLogger.record(event: StageEventRecord(
            meetingID: meetingID,
            stage: stage,
            kind: .failed,
            occurredAt: ISO8601UTC.string(from: now()),
            targetState: transition.targetState,
            errorMessage: reason.errorMessage,
            metadataJSON: buildFailedMetadataJSON(errorClass: transition.errorClass, mergingInto: nil),
            expectedState: activeState,
            expectedUpdatedAt: expectedUpdatedAt,
        ))
        logTransition(meetingID: meetingID, stage: stage, kind: .failed, state: transition.targetState, errorClass: transition.errorClass)
    }

    /// One pass of the periodic stale-detection sweep (architecture.md:1062):
    /// scans every non-terminal meeting and synthesizes a failure for any
    /// meeting whose `updated_at` has exceeded its active state's budget.
    /// Callable directly with an injected `now` for deterministic testing —
    /// this story ships the sweep's mechanism, not a live foreground/
    /// backgrounded timer loop (no App target exists yet to drive one; the
    /// interval a future composition root uses is its own concern).
    ///
    /// Each failure is written against the `updated_at` the sweep read, so a
    /// real transition that lands between the read and the write wins: the
    /// meeting is left alone and its id is left out of the result.
    @discardableResult
    public func sweepStaleActiveStates(now: Date? = nil) async throws -> [MeetingID] {
        let asOf = now ?? self.now()
        let candidates = try await stateStore.fetchPending()
        return await sweep(candidates: candidates, asOf: asOf)
    }

    /// The sweep over an already-read candidate list, so a test can hand it a
    /// snapshot that a real write has since overtaken.
    func sweep(candidates: [Meeting], asOf: Date) async -> [MeetingID] {
        var transitioned: [MeetingID] = []

        for meeting in candidates {
            guard let activeState = PipelineState(rawValue: meeting.state) else { continue }
            guard
                let budgetSeconds = Self.staleDetectionBudgetSeconds[activeState],
                let stage = ActiveStageInFlight.stage(for: activeState)
            else { continue }

            guard let updatedAt = ISO8601UTC.date(from: meeting.updatedAt) else {
                log.warn("stale-detection sweep could not parse updated_at for a budgeted active-state meeting; skipping", [
                    "rawID": .publicSafe(meeting.id),
                    "activeState": .publicSafe(activeState.rawValue),
                    "updatedAt": .publicSafe(meeting.updatedAt),
                ])
                continue
            }
            guard asOf.timeIntervalSince(updatedAt) >= Double(budgetSeconds) else { continue }

            guard let meetingID = MeetingID(ulid: meeting.id) else {
                log.warn("stale-detection sweep found a stale meeting whose id failed ULID validation; skipping", [
                    "rawID": .publicSafe(meeting.id),
                    "activeState": .publicSafe(activeState.rawValue),
                ])
                continue
            }

            do {
                try await synthesizeFailure(
                    meetingID: meetingID,
                    stage: stage,
                    activeState: activeState,
                    reason: .staleActiveState(budgetSeconds: budgetSeconds),
                    expectedUpdatedAt: meeting.updatedAt,
                )
                log.info("stale-detection sweep synthesized failure", [
                    "meetingID": .publicSafe(meetingID),
                    "activeState": .publicSafe(activeState.rawValue),
                ])
                transitioned.append(meetingID)
            } catch StateStoreError.staleWrite {
                log.info("stale-detection sweep found the meeting had moved since it was read; leaving it as it is", [
                    "meetingID": .publicSafe(meetingID),
                    "activeState": .publicSafe(activeState.rawValue),
                ])
            } catch {
                log.warn("stale-detection sweep failed to synthesize a failure; continuing with remaining candidates", [
                    "meetingID": .publicSafe(meetingID),
                    "activeState": .publicSafe(activeState.rawValue),
                ])
            }
        }
        return transitioned
    }

    // MARK: - metadata_json / error_class folding

    /// `error_class` has no dedicated `stage_events` column — architecture.md
    /// :1211 places it inside the `failed` event's `metadata_json` payload
    /// instead, alongside whatever other structured data the stage supplied.
    /// Decodes any caller-supplied JSON object, sets `error_class` on it (or
    /// starts a fresh object), and re-encodes, using `JSONSerialization`
    /// rather than a hand-rolled string merge. Named distinctly from the
    /// `metadataJSON` parameter callers pass in — that local shadows a
    /// same-named method within its own scope.
    private func buildFailedMetadataJSON(errorClass: String, mergingInto existing: String?) -> String {
        var object: [String: Any] = [:]
        if let existing {
            if let data = existing.data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                object = decoded
            } else {
                log.warn("caller-supplied metadataJSON was not a JSON object; discarding it before folding in error_class", [
                    "metadataJSON": .sensitive(existing),
                ])
            }
        }
        object["error_class"] = errorClass

        guard
            let merged = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            let mergedString = String(data: merged, encoding: .utf8)
        else {
            return "{\"error_class\":\"\(errorClass)\"}"
        }
        return mergedString
    }
}
