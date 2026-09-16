import GRDB

/// The sole read/write API for the single SQLite database (AR-PAT-4,
/// architecture.md:1968): every caller reaches `meetings`, `stage_events`,
/// `retention_timers`, and `telemetry` through this actor's typed methods —
/// a direct `db.read`/`db.write` anywhere outside this file is a
/// code-review reject. The actor boundary gives these typed methods mutual
/// exclusion consistent with AR-PAT-6; GRDB's `DatabasePool`/`DatabaseQueue`
/// are already internally thread-safe on their own.
///
/// This story owns schema + read/write plumbing only. The partitioned
/// UPSERT writers that enforce the write-authority matrix
/// (`TelemetryRecorder`, `StageEventLogger`) are Story 1.6's, and
/// state-transition orchestration (`StageRunner`, crash recovery) is
/// Story 1.5's — neither is implemented here.
/// Thrown by `StateStore` methods that need a row to already exist and find
/// none.
public enum StateStoreError: Error, Sendable, Equatable {
    case meetingNotFound(id: String)
}

public actor StateStore {
    private let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// GUI path: `DatabasePool`-backed, migrated in place before first use
    /// (AR-DATA-1) — the GUI is always first to open the database on a
    /// fresh machine, so migration happens here and nowhere else. `path`
    /// defaults to the real production location; tests substitute a temp
    /// path rather than exercising the real `~/Library/Application Support`
    /// directory.
    public static func production(path: String? = nil) throws -> StateStore {
        let resolvedPath = try path ?? DatabasePoolFactory.productionDatabasePath()
        let pool = try DatabasePoolFactory.makePool(path: resolvedPath)
        try MigrationRegistrar.migrator.migrate(pool)
        return StateStore(writer: pool)
    }

    /// Subprocess path: `DatabaseQueue`-backed. Subprocesses never migrate
    /// (architecture.md's write-authority matrix: `schema_version.*` is
    /// written only by `GRDB.DatabaseMigrator` on GUI launch) — `path`
    /// defaults to the same production location every process shares.
    public static func subprocess(path: String? = nil) throws -> StateStore {
        let resolvedPath = try path ?? DatabasePoolFactory.productionDatabasePath()
        let queue = try DatabasePoolFactory.makeQueue(path: resolvedPath)
        return StateStore(writer: queue)
    }

    /// Test/tooling entry point for an already-open writer (e.g. an
    /// in-memory `DatabaseQueue`), migrated in place. Production code never
    /// calls this — it reaches the database only through `.production()` /
    /// `.subprocess()`.
    static func forTesting(writer: any DatabaseWriter) throws -> StateStore {
        try MigrationRegistrar.migrator.migrate(writer)
        return StateStore(writer: writer)
    }

    // MARK: - Meetings

    public func insertMeeting(_ meeting: Meeting) async throws {
        try await writer.write { db in
            var meeting = meeting
            try meeting.insert(db)
        }
    }

    public func fetchMeeting(id: String) async throws -> Meeting? {
        try await writer.read { db in
            try Meeting.fetchOne(db, key: id)
        }
    }

    /// Meetings not yet in a terminal state, per `idx_meetings_state`'s
    /// partial-index predicate.
    public func fetchPending() async throws -> [Meeting] {
        try await writer.read { db in
            try Meeting
                .filter(sql: "state NOT IN ('verified','retention_expired','discarded')")
                .fetchAll(db)
        }
    }

    public func updateMeeting(_ meeting: Meeting) async throws {
        try await writer.write { db in
            try meeting.update(db)
        }
    }

    // MARK: - Stage events

    /// Returns the inserted event with its autoincremented `id` populated.
    @discardableResult
    public func insertStageEvent(_ event: StageEvent) async throws -> StageEvent {
        try await writer.write { db in
            var event = event
            try event.insert(db)
            return event
        }
    }

    /// The combined write behind `StageRunner`'s two-transaction pattern
    /// (AR-PIPE-3): one `stage_events` insert plus one `meetings.state`
    /// update, in a single `writer.write` closure so a crash between the two
    /// is impossible — either both land or neither does. Called twice per
    /// stage execution (Txn A with `event: "started"`, Txn B with
    /// `event: "completed"` or `"failed"`), never once with both events
    /// folded together, since Txn A must be durable *before* the stage's
    /// `work` closure runs.
    ///
    /// Parameters are raw `String`s, not `PipelineState`/`PipelineStage`:
    /// this actor doesn't depend on `Orchestrator`, so it can't reference
    /// those types even if it wanted to. Callers convert via `.rawValue` at
    /// the boundary.
    @discardableResult
    public func recordStageTransition(
        meetingID: String,
        stage: String,
        event: String,
        occurredAt: String,
        targetState: String,
        durationMS: Int? = nil,
        errorMessage: String? = nil,
        metadataJSON: String? = nil
    ) async throws -> StageEvent {
        try await writer.write { db in
            var stageEvent = StageEvent(
                meetingID: meetingID,
                stage: stage,
                event: event,
                occurredAt: occurredAt,
                durationMS: durationMS,
                errorMessage: errorMessage,
                metadataJSON: metadataJSON
            )
            try stageEvent.insert(db)
            try db.execute(sql: "UPDATE meetings SET state = ? WHERE id = ?", arguments: [targetState, meetingID])
            // With foreign keys unenforced (e.g. an in-memory test queue
            // with no `PRAGMA foreign_keys = ON`), a nonexistent `meetingID`
            // would otherwise let the `stage_events` insert above succeed
            // while this UPDATE silently matches zero rows. Throwing here
            // rolls back the whole `writer.write` transaction, so the event
            // insert never lands either — the pair stays atomic.
            guard db.changesCount > 0 else {
                throw StateStoreError.meetingNotFound(id: meetingID)
            }
            return stageEvent
        }
    }

    public func fetchStageEvents(meetingID: String) async throws -> [StageEvent] {
        try await writer.read { db in
            try StageEvent
                .filter(Column("meeting_id") == meetingID)
                .order(Column("occurred_at"))
                .fetchAll(db)
        }
    }

    // MARK: - Retention timers

    public func insertRetentionTimer(_ timer: RetentionTimer) async throws {
        try await writer.write { db in
            var timer = timer
            try timer.insert(db)
        }
    }

    public func fetchRetentionTimer(meetingID: String) async throws -> RetentionTimer? {
        try await writer.read { db in
            try RetentionTimer.fetchOne(db, key: meetingID)
        }
    }

    /// Rows `RetentionScheduler`'s poll should act on this tick: `status =
    /// 'pending'` and `fires_at <= asOf`, per `idx_retention_pending_fires_at`
    /// (the index this query is shaped to use). Plain lexical `<=` on `TEXT`
    /// is correct here because every `fires_at`/`asOf` value this codebase
    /// writes is the same zero-padded ISO8601 UTC form — sorts
    /// chronologically as a string.
    public func fetchDueRetentionTimers(asOf: String) async throws -> [RetentionTimer] {
        try await writer.read { db in
            try RetentionTimer
                .filter(Column("status") == "pending")
                .filter(Column("fires_at") <= asOf)
                .fetchAll(db)
        }
    }

    // MARK: - Telemetry

    public func insertTelemetry(_ telemetry: Telemetry) async throws {
        try await writer.write { db in
            var telemetry = telemetry
            try telemetry.insert(db)
        }
    }

    public func fetchTelemetry(meetingID: String) async throws -> Telemetry? {
        try await writer.read { db in
            try Telemetry.fetchOne(db, key: meetingID)
        }
    }
}
