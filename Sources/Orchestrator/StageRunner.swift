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
public actor StageRunner {
    private let stateStore: StateStore
    private let stageEventLogger: StageEventLogger
    private let now: @Sendable () -> Date
    private let log = Log(category: "orchestrator")

    public init(
        stateStore: StateStore,
        stageEventLogger: StageEventLogger,
        now: @escaping @Sendable () -> Date = { Date() },
    ) {
        self.stateStore = stateStore
        self.stageEventLogger = stageEventLogger
        self.now = now
    }

    public enum StageOutcome: Sendable {
        case completed(targetState: PipelineState, metadataJSON: String? = nil)
        case failed(targetState: PipelineState, errorClass: String, errorMessage: String? = nil, metadataJSON: String? = nil)
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
        work: @Sendable () async throws -> StageOutcome,
    ) async throws -> StageOutcome {
        try await stageEventLogger.record(event: StageEventRecord(
            meetingID: meetingID,
            stage: stage,
            kind: .started,
            occurredAt: ISO8601UTC.string(from: now()),
            targetState: activeState,
            metadataJSON: "{}",
        ))

        let outcome = try await work()
        let occurredAt = ISO8601UTC.string(from: now())

        switch outcome {
        case let .completed(targetState, metadataJSON):
            try await stageEventLogger.record(event: StageEventRecord(
                meetingID: meetingID,
                stage: stage,
                kind: .completed,
                occurredAt: occurredAt,
                targetState: targetState,
                metadataJSON: metadataJSON,
            ))
        case let .failed(targetState, errorClass, errorMessage, metadataJSON):
            try await stageEventLogger.record(event: StageEventRecord(
                meetingID: meetingID,
                stage: stage,
                kind: .failed,
                occurredAt: occurredAt,
                targetState: targetState,
                errorMessage: errorMessage,
                metadataJSON: buildFailedMetadataJSON(errorClass: errorClass, mergingInto: metadataJSON),
            ))
        }
        return outcome
    }

    // MARK: - Stale-detection synthesis

    /// Per-state wall-clock stale-detection budgets, in seconds (AR-FAIL-2 /
    /// Decision 4.2, architecture.md:1054-1060): `transcribing` 2× NFR-P3
    /// (60s), `reviewingDiarization` 90s fixed, `summarizing` 2× NFR-P5
    /// (720s — architecture's own stated ≈12min figure), `published` 30s.
    /// `attributing` is intentionally absent — user-paced, no auto-failure.
    public static let staleDetectionBudgetSeconds: [PipelineState: Int] = [
        .transcribing: 60,
        .reviewingDiarization: 90,
        .summarizing: 720,
        .published: 30,
    ]

    private struct StaleTransition {
        let targetState: PipelineState
        let errorClass: String
    }

    /// The exact per-state table from the I/O matrix: `reviewingDiarization`
    /// and `published` are benign passthroughs (not `*_failed`);
    /// `transcribing`/`summarizing` are the general "stale → `*_failed`"
    /// case. `published`'s passthrough is a narrow, explicit carve-out of
    /// the AC's general rule, not this table forgetting to fail it —
    /// `published_partial` is a distinct, unrelated trigger (only
    /// `--publish-anyway` + no summarize output) and never fires for a stuck
    /// notify.
    private static func staleTransition(for activeState: PipelineState) -> StaleTransition? {
        switch activeState {
        case .transcribing:
            StaleTransition(targetState: .transcriptionFailed, errorClass: "stale_active_state")
        case .reviewingDiarization:
            StaleTransition(targetState: .awaitingAttribution, errorClass: "ai_reviewer_timeout")
        case .summarizing:
            StaleTransition(targetState: .summarizationFailed, errorClass: "stale_active_state")
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
    public func synthesizeFailure(
        meetingID: MeetingID,
        stage: PipelineStage,
        activeState: PipelineState,
        reason: StaleFailureReason,
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
        ))
    }

    /// One pass of the periodic stale-detection sweep (architecture.md:1062):
    /// scans every non-terminal meeting and synthesizes a failure for any
    /// meeting whose `updated_at` has exceeded its active state's budget.
    /// Callable directly with an injected `now` for deterministic testing —
    /// this story ships the sweep's mechanism, not a live foreground/
    /// backgrounded timer loop (no App target exists yet to drive one; the
    /// interval a future composition root uses is its own concern).
    @discardableResult
    public func sweepStaleActiveStates(now: Date? = nil) async throws -> [MeetingID] {
        let asOf = now ?? self.now()
        let candidates = try await stateStore.fetchPending()
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
                )
                log.info("stale-detection sweep synthesized failure", [
                    "meetingID": .publicSafe(meetingID),
                    "activeState": .publicSafe(activeState.rawValue),
                ])
                transitioned.append(meetingID)
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
                    "metadataJSON": .publicSafe(existing),
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
