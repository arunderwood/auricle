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

@Test func subprocessAtFreshPathDoesNotMigrate() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    _ = try StateStore.subprocess(path: path)

    let inspector = try DatabaseQueue(path: path)
    let tableExists = try inspector.read { db in try db.tableExists("meetings") }
    #expect(!tableExists, "StateStore.subprocess(path:) must not run migrations itself")
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
