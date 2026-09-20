import Core
import Foundation
import GRDB
@testable import State
import Testing

/// Exercises `StateStore.production(path:)` and `StateStore.subprocess(path:)`
/// themselves — the two factory methods the I/O matrix names directly as
/// "Input / State" under test — rather than only the `DatabasePoolFactory`
/// primitives underneath them. `path` substitutes a temp directory for the
/// real `~/Library/Application Support/com.auricle.app/` location so these
/// run as ordinary unit tests.
///
/// A `StateStore` actor exposes no schema-introspection API of its own (by
/// design — typed methods only, per AR-PAT-4), so these tests open a second,
/// independent connection to the same path after the factory call returns
/// and inspect the schema through it — exactly how a second real process
/// would observe what the first one wrote.
private func makeTestDatabasePath() -> (directory: URL, path: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("auricle.sqlite3").path)
}

@Test func productionAtFreshPathCreatesFileWithWALAndFullSchema() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try StateStore.production(path: path)

    #expect(FileManager.default.fileExists(atPath: path))

    let inspector = try DatabaseQueue(path: path)
    try inspector.read { db in
        let journalMode = try String.fetchOne(db, sql: "PRAGMA journal_mode")
        #expect(journalMode == "wal")

        for table in ["schema_version", "meetings", "stage_events", "retention_timers", "telemetry"] {
            let exists = try db.tableExists(table)
            #expect(exists, "expected table \(table) to exist after StateStore.production(path:)")
        }

        let triggerExists = try db.triggerExists("meetings_updated_at")
        #expect(triggerExists)

        let meetingsIndexes = try db.indexes(on: "meetings").map(\.name)
        #expect(meetingsIndexes.contains("idx_meetings_state"))
        let stageEventsIndexes = try db.indexes(on: "stage_events").map(\.name)
        #expect(stageEventsIndexes.contains("idx_stage_events_meeting"))
        let retentionTimersIndexes = try db.indexes(on: "retention_timers").map(\.name)
        #expect(retentionTimersIndexes.contains("idx_retention_pending_fires_at"))
    }
}

@Test func productionIsIdempotentWhenReopeningAnAlreadyMigratedPath() async throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try StateStore.production(path: path)
    // A second `.production(path:)` call at the same path — the GUI
    // relaunching against a database migration #1 already created — must
    // not fail or re-run the migration.
    let store = try StateStore.production(path: path)

    try await store.insertMeeting(
        Meeting(id: "01REOPENEDPRODUCTIONMEETIN", state: "recording", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"),
    )
    let fetched = try await store.fetchMeeting(id: "01REOPENEDPRODUCTIONMEETIN")
    #expect(fetched?.id == "01REOPENEDPRODUCTIONMEETIN")
}

/// What a rejected open must leave behind: the directory exactly as it was, so
/// no database, journal or shared-memory file has been created or altered.
private func directorySnapshot(_ directory: URL) throws -> [String: Int] {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    return try Dictionary(uniqueKeysWithValues: names.map { name in
        let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)[.size] as? Int
        return (name, size ?? -1)
    })
}

/// A database that holds only the first three migrations, as a GUI build from
/// before migration #4 would have left it.
private func makeDatabaseWithMigrationsOneToThree(at path: String) throws {
    var migrator = DatabaseMigrator()
    migrator.registerMigration(Migration001Initial.identifier, migrate: Migration001Initial.migrate)
    migrator.registerMigration(Migration002StageEventsMetadataSchemaVersion.identifier, migrate: Migration002StageEventsMetadataSchemaVersion.migrate)
    migrator.registerMigration(Migration003RenameAudioRetentionStatusColumn.identifier, migrate: Migration003RenameAudioRetentionStatusColumn.migrate)
    let queue = try DatabaseQueue(path: path)
    try migrator.migrate(queue)
}

@Test func subprocessAtAMissingPathThrowsDatabaseNotFoundAndCreatesNothing() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: StateStoreError.databaseNotFound) {
        try StateStore.subprocess(path: path)
    }

    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(try directorySnapshot(directory).isEmpty)
}

@Test func subprocessAtAnEmptyFileThrowsSchemaNotMigratedAndLeavesTheFileAlone() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    try AtomicWriter.write(Data(), to: URL(fileURLWithPath: path))
    let before = try directorySnapshot(directory)

    #expect(throws: StateStoreError.schemaNotMigrated) {
        try StateStore.subprocess(path: path)
    }

    #expect(try directorySnapshot(directory) == before)
}

@Test func subprocessAtADatabaseWithOnlyTheFirstThreeMigrationsThrowsSchemaNotMigrated() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeDatabaseWithMigrationsOneToThree(at: path)
    let before = try directorySnapshot(directory)

    #expect(throws: StateStoreError.schemaNotMigrated) {
        try StateStore.subprocess(path: path)
    }

    #expect(try directorySnapshot(directory) == before)
}

@Test func subprocessAtADatabaseANewerBinaryMigratedThrowsSchemaSuperseded() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try StateStore.production(path: path)
    let inspector = try DatabaseQueue(path: path)
    try inspector.write { db in
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('999_from_a_newer_binary')")
    }

    #expect(throws: StateStoreError.schemaSuperseded) {
        try StateStore.subprocess(path: path)
    }
}

@Test func subprocessAtACurrentDatabaseOpensAndWrites() async throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try StateStore.production(path: path)

    let store = try StateStore.subprocess(path: path)
    try await store.insertMeeting(
        Meeting(id: "01SUBPROCESSOPENSMEETING00", state: "recording", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"),
    )

    #expect(try await store.fetchMeeting(id: "01SUBPROCESSOPENSMEETING00") != nil)
}

@Test func readerAtAMissingPathThrowsDatabaseNotFoundAndCreatesNeitherDirectoryNorFile() throws {
    let (directory, _) = makeTestDatabasePath()
    let missingDirectory = directory.appendingPathComponent("not-created")
    let path = missingDirectory.appendingPathComponent("auricle.sqlite3").path
    defer { try? FileManager.default.removeItem(at: directory) }

    #expect(throws: StateStoreError.databaseNotFound) {
        try StateStore.reader(path: path)
    }

    #expect(!FileManager.default.fileExists(atPath: missingDirectory.path))
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func readerRejectsAnOldOrNewerSchemaWithoutTouchingTheFile() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeDatabaseWithMigrationsOneToThree(at: path)
    let before = try directorySnapshot(directory)

    #expect(throws: StateStoreError.schemaNotMigrated) {
        try StateStore.reader(path: path)
    }
    #expect(try directorySnapshot(directory) == before)

    let current = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: current.directory) }
    _ = try StateStore.production(path: current.path)
    try DatabaseQueue(path: current.path).write { db in
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('999_from_a_newer_binary')")
    }
    #expect(throws: StateStoreError.schemaSuperseded) {
        try StateStore.reader(path: current.path)
    }
}

@Test func readerReadsWhatProductionWrote() async throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let production = try StateStore.production(path: path)
    try await production.insertMeeting(
        Meeting(id: "01READERREADSMEETING0000", state: "awaiting_attribution", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"),
    )

    let reader = try StateStore.reader(path: path)

    #expect(try await reader.fetchPending().map(\.id) == ["01READERREADSMEETING0000"])
}

// MARK: - A WAL database with no `-wal` and no `-shm`

/// A WAL-mode database left the way its last clean close leaves it: the schema
/// in the main file and no `-wal` or `-shm` beside it. This is the state a
/// process finds after the app has quit, and a `SQLITE_OPEN_READONLY`
/// connection cannot open a WAL database in it.
private func makeWALDatabaseWithoutSidecars(
    at path: String,
    migrator: DatabaseMigrator,
    plusIdentifier extraIdentifier: String? = nil,
) throws {
    var configuration = Configuration()
    configuration.journalMode = .wal
    do {
        let queue = try DatabaseQueue(path: path, configuration: configuration)
        try migrator.migrate(queue)
        if let extraIdentifier {
            try queue.write { db in
                try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [extraIdentifier])
            }
        }
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
    }
    for suffix in ["-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
    }
}

/// Bytes 18 and 19 of the file header are 2 for a WAL database. Asserted so a
/// setup that silently produced a rollback-journal file cannot pass these tests.
private func expectWALHeader(at path: String) throws {
    let header = try Data(contentsOf: URL(fileURLWithPath: path)).prefix(20)
    #expect(header[18] == 2 && header[19] == 2)
}

private func expectNoSidecars(beside path: String, in directory: URL) throws {
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [URL(fileURLWithPath: path).lastPathComponent])
}

@Test func aCleanlyClosedWALDatabaseWithNoSidecarsOpensForReaderAndSubprocess() async throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeWALDatabaseWithoutSidecars(at: path, migrator: MigrationRegistrar.migrator)
    try expectWALHeader(at: path)
    try expectNoSidecars(beside: path, in: directory)

    let reader = try StateStore.reader(path: path)
    #expect(try await reader.fetchPending().isEmpty)

    let store = try StateStore.subprocess(path: path)
    try await store.insertMeeting(
        Meeting(id: "01WALNOSIDECARSSUBPROC00", state: "recording", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"),
    )
    #expect(try await store.fetchMeeting(id: "01WALNOSIDECARSSUBPROC00") != nil)
    #expect(try await reader.fetchMeeting(id: "01WALNOSIDECARSSUBPROC00") != nil)
}

@Test func aWALDatabaseWithNoSidecarsAndOnlyThreeMigrationsIsRejectedAndLeftUnchanged() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    var oldMigrator = DatabaseMigrator()
    oldMigrator.registerMigration(Migration001Initial.identifier, migrate: Migration001Initial.migrate)
    oldMigrator.registerMigration(Migration002StageEventsMetadataSchemaVersion.identifier, migrate: Migration002StageEventsMetadataSchemaVersion.migrate)
    oldMigrator.registerMigration(Migration003RenameAudioRetentionStatusColumn.identifier, migrate: Migration003RenameAudioRetentionStatusColumn.migrate)
    try makeWALDatabaseWithoutSidecars(at: path, migrator: oldMigrator)
    try expectWALHeader(at: path)
    try expectNoSidecars(beside: path, in: directory)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))

    #expect(throws: StateStoreError.schemaNotMigrated) {
        try StateStore.reader(path: path)
    }
    #expect(throws: StateStoreError.schemaNotMigrated) {
        try StateStore.subprocess(path: path)
    }

    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    try expectWALHeader(at: path)
}

@Test func aWALDatabaseWithNoSidecarsThatANewerBinaryMigratedIsRejectedAndLeftUnchanged() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    try makeWALDatabaseWithoutSidecars(at: path, migrator: MigrationRegistrar.migrator, plusIdentifier: "999_from_a_newer_binary")
    try expectWALHeader(at: path)
    try expectNoSidecars(beside: path, in: directory)
    let before = try Data(contentsOf: URL(fileURLWithPath: path))

    #expect(throws: StateStoreError.schemaSuperseded) {
        try StateStore.reader(path: path)
    }
    #expect(throws: StateStoreError.schemaSuperseded) {
        try StateStore.subprocess(path: path)
    }

    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == before)
    try expectWALHeader(at: path)
}

@Test func subprocessReadsWhatProductionMigratedAtTheSharedPath() async throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    let guiStore = try StateStore.production(path: path)
    try await guiStore.insertMeeting(
        Meeting(id: "01SHAREDPATHMEETINGID00000", state: "recording", createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z"),
    )

    let subprocessStore = try StateStore.subprocess(path: path)
    let fetched = try await subprocessStore.fetchMeeting(id: "01SHAREDPATHMEETINGID00000")
    #expect(fetched?.id == "01SHAREDPATHMEETINGID00000")
}

/// A subprocess never migrates, so the GUI's production opener is what adds
/// migration #4's telemetry columns; the subprocess then writes and reads them
/// through its own connection.
@Test func theProductionOpenerAddsTheSummarizeTelemetryColumnsThatASubprocessThenWrites() async throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let meetingID = "01FACTORYFOURMEETINGID000"
    let hash = String(repeating: "0a", count: 32)

    let production = try StateStore.production(path: path)
    try await production.insertMeeting(Meeting(
        id: meetingID,
        state: "summarizing",
        createdAt: "2026-01-01T00:00:00Z",
        updatedAt: "2026-01-01T00:00:00Z",
    ))

    let subprocess = try StateStore.subprocess(path: path)
    try await subprocess.upsertTelemetry(
        Telemetry(meetingID: meetingID, groundingMethod: "citations", summarizationPromptSetHash: hash),
    )

    let fetched = try #require(try await production.fetchTelemetry(meetingID: meetingID))
    #expect(fetched.groundingMethod == "citations")
    #expect(fetched.summarizationPromptSetHash == hash)
}
