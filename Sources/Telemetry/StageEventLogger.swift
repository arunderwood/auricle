import Core
import State

/// The 4 `stage_events.event` values a `StageEventRecord` can carry
/// (architecture.md Decision 4.5). `started`/`completed`/`failed` are Txn A/
/// Txn B of `StageRunner`'s two-transaction pattern and carry a
/// `targetState`; `retried` fires mid-stage, between the two, and never
/// changes `meetings.state`.
public enum StageEventKind: String, Sendable, Equatable {
    case started
    case completed
    case failed
    case retried
}

/// The typed request `StageEventLogger.record(event:)` accepts. `stage` and
/// `targetState` are the closed enums (`PipelineStage`/`PipelineState`), not
/// raw strings — `.rawValue` conversion happens once, at the boundary into
/// `StateStore`. `metadataJSON` is already-serialized, snake_case-dialect
/// JSON (AR-PAT-2): the stage that produced it did its own
/// `StageMetadata` → JSON encoding at its own call site (Decision 4.5's
/// "typed at the call site" step); this logger's job is routing the result
/// to the right `StateStore` write, not re-deriving it.
public struct StageEventRecord: Sendable {
    public var meetingID: MeetingID
    public var stage: PipelineStage
    public var kind: StageEventKind
    public var occurredAt: String
    public var targetState: PipelineState?
    public var durationMS: Int?
    public var errorMessage: String?
    public var metadataJSON: String?

    public init(
        meetingID: MeetingID,
        stage: PipelineStage,
        kind: StageEventKind,
        occurredAt: String,
        targetState: PipelineState? = nil,
        durationMS: Int? = nil,
        errorMessage: String? = nil,
        metadataJSON: String? = nil,
    ) {
        self.meetingID = meetingID
        self.stage = stage
        self.kind = kind
        self.occurredAt = occurredAt
        self.targetState = targetState
        self.durationMS = durationMS
        self.errorMessage = errorMessage
        self.metadataJSON = metadataJSON
    }
}

/// The sole writer of `stage_events` rows (AR-PAT-4): every stage's
/// `started`/`completed`/`failed`/`retried` transition, whether via
/// `StageRunner`'s two-transaction pattern or a future direct `retried`
/// call, funnels through `record(event:)` rather than calling
/// `StateStore.recordStageTransition`/`insertStageEvent` directly — this
/// actor wraps those calls, unchanged, and is the only caller of them.
public actor StageEventLogger {
    /// The `StageMetadata` shape this logger's callers currently encode
    /// against (Decision 4.5). A future incompatible reshaping of
    /// `StageMetadata` bumps this constant, independent of any
    /// `stage_events` table migration.
    public static let currentMetadataSchemaVersion = 1

    public enum RecordError: Error, Sendable, Equatable {
        /// `started`/`completed`/`failed` transition `meetings.state` and so
        /// require a `targetState`; only `retried` may omit one. A record
        /// that violates this can't be expressed as a valid `StateStore`
        /// call, so it's rejected here rather than passed further down.
        case missingTargetState(kind: StageEventKind)
        /// `retried` never changes `meetings.state` — `insertStageEvent`
        /// has no `targetState` parameter to give one to. A caller that
        /// sets one anyway is asking for a state change this event kind
        /// cannot perform, so it's rejected rather than silently dropped.
        case unexpectedTargetState(kind: StageEventKind)
    }

    private let stateStore: StateStore

    public init(stateStore: StateStore) {
        self.stateStore = stateStore
    }

    public func record(event: StageEventRecord) async throws {
        switch event.kind {
        case .started, .completed, .failed:
            guard let targetState = event.targetState else {
                throw RecordError.missingTargetState(kind: event.kind)
            }
            try await stateStore.recordStageTransition(
                meetingID: event.meetingID.rawValue,
                stage: event.stage.rawValue,
                event: event.kind.rawValue,
                occurredAt: event.occurredAt,
                targetState: targetState.rawValue,
                durationMS: event.durationMS,
                errorMessage: event.errorMessage,
                metadataJSON: event.metadataJSON,
                metadataSchemaVersion: Self.currentMetadataSchemaVersion,
            )
        case .retried:
            guard event.targetState == nil else {
                throw RecordError.unexpectedTargetState(kind: event.kind)
            }
            try await stateStore.insertStageEvent(
                StageEvent(
                    meetingID: event.meetingID.rawValue,
                    stage: event.stage.rawValue,
                    event: event.kind.rawValue,
                    occurredAt: event.occurredAt,
                    durationMS: event.durationMS,
                    errorMessage: event.errorMessage,
                    metadataJSON: event.metadataJSON,
                    metadataSchemaVersion: Self.currentMetadataSchemaVersion,
                ),
            )
        }
    }
}
