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
