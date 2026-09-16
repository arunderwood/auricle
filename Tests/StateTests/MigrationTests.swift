import Foundation
import GRDB
import Testing
@testable import State

private func makeTestDatabasePath() -> (directory: URL, path: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("auricle.sqlite3").path)
}

private func columnInfo(_ name: String, in columns: [ColumnInfo]) -> ColumnInfo? {
    columns.first { $0.name == name }
}

@Test func migrationAppliesCleanlyToEmptyDatabase() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let appliedIdentifiers = try queue.read { db in
        try MigrationRegistrar.migrator.appliedIdentifiers(db)
    }
    #expect(appliedIdentifiers == [
        Migration001Initial.identifier,
        Migration002StageEventsMetadataSchemaVersion.identifier,
    ])
}

/// The first genuine schema-upgrade path in this codebase: a database that
/// already has migration #1's schema and a real `stage_events` row,
/// upgraded in place by migration #2. `metadata_schema_version` has no
/// application-level writer for a row inserted before that column existed —
/// its `DEFAULT 1` clause is what has to backfill the pre-existing row.
@Test func migrationTwoBackfillsMetadataSchemaVersionOnAPreExistingStageEventsRow() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    let queue = try DatabasePoolFactory.makeQueue(path: path)
    var migrationOneOnly = DatabaseMigrator()
    migrationOneOnly.registerMigration(Migration001Initial.identifier, migrate: Migration001Initial.migrate)
    try migrationOneOnly.migrate(queue)

    try queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO meetings (id, state, created_at, updated_at)
            VALUES ('01PREMIGRATIONMEETINGID00', 'recording', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """
        )
        try db.execute(
            sql: """
            INSERT INTO stage_events (meeting_id, stage, event, occurred_at)
            VALUES ('01PREMIGRATIONMEETINGID00', 'capture', 'started', '2026-01-01T00:00:00Z')
            """
        )
    }

    try MigrationRegistrar.migrator.migrate(queue)

    let backfilledVersion = try queue.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT metadata_schema_version FROM stage_events WHERE meeting_id = '01PREMIGRATIONMEETINGID00'"
        )
    }
    #expect(backfilledVersion == 1)
}

@Test func journalModeIsWALForBothOpeners() throws {
    let (poolDirectory, poolPath) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: poolDirectory) }
    let pool = try DatabasePoolFactory.makePool(path: poolPath)
    try MigrationRegistrar.migrator.migrate(pool)
    let poolJournalMode = try pool.read { db in
        try String.fetchOne(db, sql: "PRAGMA journal_mode")
    }
    #expect(poolJournalMode == "wal")

    let (queueDirectory, queuePath) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: queueDirectory) }
    let queue = try DatabasePoolFactory.makeQueue(path: queuePath)
    try MigrationRegistrar.migrator.migrate(queue)
    let queueJournalMode = try queue.read { db in
        try String.fetchOne(db, sql: "PRAGMA journal_mode")
    }
    #expect(queueJournalMode == "wal")
}

@Test func foreignKeysPragmaIsOnForBothOpeners() throws {
    let (poolDirectory, poolPath) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: poolDirectory) }
    let pool = try DatabasePoolFactory.makePool(path: poolPath)
    let poolForeignKeys = try pool.read { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") }
    #expect(poolForeignKeys == true)

    let (queueDirectory, queuePath) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: queueDirectory) }
    let queue = try DatabasePoolFactory.makeQueue(path: queuePath)
    let queueForeignKeys = try queue.read { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") }
    #expect(queueForeignKeys == true)
}

@Test func allFiveTablesExist() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    try queue.read { db in
        for table in ["schema_version", "meetings", "stage_events", "retention_timers", "telemetry"] {
            let exists = try db.tableExists(table)
            #expect(exists, "expected table \(table) to exist")
        }
    }
}

@Test func meetingsUpdatedAtTriggerExists() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let exists = try queue.read { db in try db.triggerExists("meetings_updated_at") }
    #expect(exists)
}

@Test func meetingsUpdatedAtTriggerMaintainsTimestampOnUpdate() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    try queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO meetings (id, state, created_at, updated_at)
            VALUES ('01TESTMEETINGID0000000000', 'recording', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """
        )
    }
    let originalUpdatedAt = try queue.read { db in
        try String.fetchOne(db, sql: "SELECT updated_at FROM meetings WHERE id = '01TESTMEETINGID0000000000'")
    }

    // The trigger stamps `updated_at` with `strftime(..., 'now')`, which is
    // second-resolution unless a fractional-seconds format is requested;
    // sleeping past a whole second makes the before/after comparison
    // reliable rather than racing the clock's own tick.
    Thread.sleep(forTimeInterval: 1.1)

    try queue.write { db in
        try db.execute(sql: "UPDATE meetings SET state = 'transcribing' WHERE id = '01TESTMEETINGID0000000000'")
    }
    let updatedUpdatedAt = try queue.read { db in
        try String.fetchOne(db, sql: "SELECT updated_at FROM meetings WHERE id = '01TESTMEETINGID0000000000'")
    }

    #expect(updatedUpdatedAt != originalUpdatedAt)
}

@Test func meetingsColumnsMatchSchema() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let columns = try queue.read { db in try db.columns(in: "meetings") }

    let id = try #require(columnInfo("id", in: columns))
    #expect(id.type.uppercased() == "TEXT")
    #expect(id.primaryKeyIndex == 1)

    let state = try #require(columnInfo("state", in: columns))
    #expect(state.type.uppercased() == "TEXT")
    #expect(state.isNotNull)

    let createdAt = try #require(columnInfo("created_at", in: columns))
    #expect(createdAt.isNotNull)

    let updatedAt = try #require(columnInfo("updated_at", in: columns))
    #expect(updatedAt.isNotNull)

    for nullableTextColumn in [
        "capture_started_at", "capture_ended_at", "title", "calendar_event_id",
        "vault_note_path", "audio_cache_path", "verified_at", "retention_policy",
    ] {
        let column = try #require(columnInfo(nullableTextColumn, in: columns))
        #expect(!column.isNotNull, "expected \(nullableTextColumn) to be nullable")
    }

    let durationSeconds = try #require(columnInfo("duration_seconds", in: columns))
    #expect(durationSeconds.type.uppercased() == "INTEGER")
    #expect(!durationSeconds.isNotNull)
}

@Test func stageEventsColumnsMatchSchema() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let columns = try queue.read { db in try db.columns(in: "stage_events") }

    let id = try #require(columnInfo("id", in: columns))
    #expect(id.type.uppercased() == "INTEGER")
    #expect(id.primaryKeyIndex == 1)

    for notNullColumn in ["meeting_id", "stage", "event", "occurred_at"] {
        let column = try #require(columnInfo(notNullColumn, in: columns))
        #expect(column.isNotNull, "expected \(notNullColumn) to be NOT NULL")
    }

    for nullableColumn in ["duration_ms", "error_message", "metadata_json"] {
        let column = try #require(columnInfo(nullableColumn, in: columns))
        #expect(!column.isNotNull, "expected \(nullableColumn) to be nullable")
    }
}

@Test func stageEventsMetadataSchemaVersionColumnExistsAfterMigrationTwo() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let columns = try queue.read { db in try db.columns(in: "stage_events") }

    let metadataSchemaVersion = try #require(columnInfo("metadata_schema_version", in: columns))
    #expect(metadataSchemaVersion.type.uppercased() == "INTEGER")
    #expect(!metadataSchemaVersion.isNotNull)
    #expect(metadataSchemaVersion.defaultValueSQL == "1")
}

@Test func retentionTimersColumnsMatchSchema() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let columns = try queue.read { db in try db.columns(in: "retention_timers") }

    let meetingID = try #require(columnInfo("meeting_id", in: columns))
    #expect(meetingID.primaryKeyIndex == 1)

    for notNullColumn in ["armed_at", "fires_at", "status"] {
        let column = try #require(columnInfo(notNullColumn, in: columns))
        #expect(column.isNotNull, "expected \(notNullColumn) to be NOT NULL")
    }

    let status = try #require(columnInfo("status", in: columns))
    #expect(status.defaultValueSQL == "'pending'")

    let lastRemindedAt = try #require(columnInfo("last_reminded_at", in: columns))
    #expect(!lastRemindedAt.isNotNull)
}

@Test func telemetryColumnsMatchSchema() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let columns = try queue.read { db in try db.columns(in: "telemetry") }

    let meetingID = try #require(columnInfo("meeting_id", in: columns))
    #expect(meetingID.primaryKeyIndex == 1)

    // All 20 wedge-validation / trust-calibration counter columns from
    // architecture.md:742-767 (Amelia's Story 1 blocker): every one must
    // exist from migration #1, even the sparse `transcription_*` slots
    // with no MVP writer.
    let expectedColumns = [
        "time_to_attribution_ready_seconds",
        "time_to_vault_note_seconds",
        "transcription_wer_estimate",
        "quote_validation_drop_count",
        "attribution_completion_path",
        "summarization_path",
        "summarization_model",
        "summarization_effort_budget",
        "cost_usd",
        "diarization_suggestions_count",
        "diarization_suggestions_applied_count",
        "diarization_suggestions_rejected_count",
        "diarization_review_cost_usd",
        "diarization_review_model",
        "transcription_suggestions_count",
        "transcription_suggestions_applied_count",
        "transcription_suggestions_rejected_count",
        "transcription_review_cost_usd",
        "transcription_review_model",
        "audio_retention_status_at_30d",
    ]
    for expectedColumn in expectedColumns {
        #expect(columnInfo(expectedColumn, in: columns) != nil, "expected telemetry column \(expectedColumn) to exist")
    }
    #expect(columns.count == expectedColumns.count + 1, "expected exactly the 20 counter columns plus meeting_id")

    let werEstimate = try #require(columnInfo("transcription_wer_estimate", in: columns))
    #expect(werEstimate.type.uppercased() == "REAL")

    let costUSD = try #require(columnInfo("cost_usd", in: columns))
    #expect(costUSD.type.uppercased() == "REAL")
}

@Test func schemaVersionColumnsMatchSchema() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let columns = try queue.read { db in try db.columns(in: "schema_version") }
    let version = try #require(columnInfo("version", in: columns))
    #expect(version.primaryKeyIndex == 1)
    let appliedAt = try #require(columnInfo("applied_at", in: columns))
    #expect(appliedAt.isNotNull)
}

@Test func allThreeIndexesExist() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    try queue.read { db in
        let meetingsIndexes = try db.indexes(on: "meetings").map(\.name)
        #expect(meetingsIndexes.contains("idx_meetings_state"))

        let stageEventsIndexes = try db.indexes(on: "stage_events").map(\.name)
        #expect(stageEventsIndexes.contains("idx_stage_events_meeting"))

        let retentionTimersIndexes = try db.indexes(on: "retention_timers").map(\.name)
        #expect(retentionTimersIndexes.contains("idx_retention_pending_fires_at"))
    }
}

@Test func idxMeetingsStateIsPartial() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let sql = try queue.read { db in
        try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_meetings_state'")
    }
    let indexSQL = try #require(sql)
    #expect(indexSQL.contains("WHERE"))
    #expect(indexSQL.contains("NOT IN"))
}

@Test func idxRetentionPendingFiresAtIsPartial() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    let sql = try queue.read { db in
        try String.fetchOne(
            db,
            sql: "SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_retention_pending_fires_at'"
        )
    }
    let indexSQL = try #require(sql)
    #expect(indexSQL.contains("WHERE status = 'pending'"))
}

/// Covers `DatabasePoolFactory`'s `foreignKeysEnabled = true` (AR-DATA-2):
/// deleting a `meetings` row must cascade to every child table's rows via
/// their `ON DELETE CASCADE` foreign keys.
@Test func deletingMeetingCascadesToChildTables() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    try queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO meetings (id, state, created_at, updated_at)
            VALUES ('01CASCADETESTMEETINGID000', 'recording', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
            """
        )
        try db.execute(
            sql: """
            INSERT INTO stage_events (meeting_id, stage, event, occurred_at)
            VALUES ('01CASCADETESTMEETINGID000', 'capture', 'started', '2026-01-01T00:00:00Z')
            """
        )
        try db.execute(
            sql: """
            INSERT INTO retention_timers (meeting_id, armed_at, fires_at)
            VALUES ('01CASCADETESTMEETINGID000', '2026-01-01T00:00:00Z', '2026-01-31T00:00:00Z')
            """
        )
        try db.execute(sql: "INSERT INTO telemetry (meeting_id) VALUES ('01CASCADETESTMEETINGID000')")
    }

    try queue.write { db in
        try db.execute(sql: "DELETE FROM meetings WHERE id = '01CASCADETESTMEETINGID000'")
    }

    try queue.read { db in
        let stageEventsCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM stage_events WHERE meeting_id = '01CASCADETESTMEETINGID000'"
        )
        #expect(stageEventsCount == 0)
        let retentionTimersCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM retention_timers WHERE meeting_id = '01CASCADETESTMEETINGID000'"
        )
        #expect(retentionTimersCount == 0)
        let telemetryCount = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM telemetry WHERE meeting_id = '01CASCADETESTMEETINGID000'"
        )
        #expect(telemetryCount == 0)
    }
}

/// The other half of `foreignKeysEnabled = true`'s coverage: an insert
/// referencing a `meeting_id` that doesn't exist is rejected rather than
/// silently creating an orphan row.
@Test func insertingStageEventForNonexistentMeetingThrows() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DatabasePoolFactory.makeQueue(path: path)
    try MigrationRegistrar.migrator.migrate(queue)

    #expect(throws: DatabaseError.self) {
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO stage_events (meeting_id, stage, event, occurred_at)
                VALUES ('01NONEXISTENTMEETINGID000', 'capture', 'started', '2026-01-01T00:00:00Z')
                """
            )
        }
    }
}
