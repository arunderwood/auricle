import Foundation
import GRDB
@testable import State
import Testing

private func makeTestDatabasePath() -> (directory: URL, path: String) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (directory, directory.appendingPathComponent("auricle.sqlite3").path)
}

/// A `Configuration` matching `DatabasePoolFactory`'s (WAL, foreign keys on)
/// but with a caller-supplied busy timeout, so contention tests can use a
/// short timeout instead of production's 5s and stay fast.
private func makeConfiguration(busyTimeoutSeconds: TimeInterval) -> Configuration {
    var configuration = Configuration()
    configuration.busyMode = .timeout(busyTimeoutSeconds)
    configuration.foreignKeysEnabled = true
    configuration.journalMode = .wal
    return configuration
}

private func insertMeetingSQL(id: String) -> String {
    """
    INSERT INTO meetings (id, state, created_at, updated_at)
    VALUES ('\(id)', 'recording', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')
    """
}

@Test func databasePoolFactoryOpenersUseWALAndFiveSecondBusyTimeout() throws {
    let (poolDirectory, poolPath) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: poolDirectory) }
    let pool = try DatabasePoolFactory.makePool(path: poolPath)
    // Query through `write`, not `read`: `DatabasePool` has separate reader
    // and writer connections, and only the writer's busy mode is
    // `Configuration.busyMode` — readers fall back to GRDB's own default
    // (`readonlyBusyMode`) unless configured separately, so reading this
    // pragma through a reader connection would assert the wrong value.
    let poolBusyTimeoutMS = try pool.write { db in try Int.fetchOne(db, sql: "PRAGMA busy_timeout") }
    #expect(poolBusyTimeoutMS == 5000)

    let (queueDirectory, queuePath) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: queueDirectory) }
    let queue = try DatabasePoolFactory.makeQueue(path: queuePath)
    let queueBusyTimeoutMS = try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA busy_timeout") }
    #expect(queueBusyTimeoutMS == 5000)
}

/// Simulates the GUI (`DatabasePool`) and a subprocess (`DatabaseQueue`)
/// briefly holding the write lock at the same time. This mirrors AR-DATA-2's
/// concurrency model with two independent connections to the same WAL file
/// rather than two OS processes — SQLite's own locking doesn't distinguish
/// same-process from cross-process connections, so this exercises the exact
/// mechanism the architecture depends on.
@Test func writeContentionWithinBusyTimeoutSucceedsWithoutError() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    // Seed the schema before the contending connections open.
    try MigrationRegistrar.migrator.migrate(DatabaseQueue(path: path, configuration: makeConfiguration(busyTimeoutSeconds: 5)))

    let guiPool = try DatabasePool(path: path, configuration: makeConfiguration(busyTimeoutSeconds: 5))
    let subprocessQueue = try DatabaseQueue(path: path, configuration: makeConfiguration(busyTimeoutSeconds: 5))

    let lockAcquired = DispatchSemaphore(value: 0)
    let releaseLock = DispatchSemaphore(value: 0)

    let holderThread = Thread {
        try? guiPool.write { db in
            // `lockAcquired.signal()` is scoped to this `do` block via
            // `defer` so it fires whether the insert throws or succeeds —
            // if it only ran after a successful insert, a throw here would
            // leave the main thread's `lockAcquired.wait()` blocked forever.
            do {
                defer { lockAcquired.signal() }
                try db.execute(sql: insertMeetingSQL(id: "01HOLDERMEETINGID000000000"))
            }
            releaseLock.wait()
        }
    }
    holderThread.start()
    lockAcquired.wait()

    // Release the GUI's write lock ~0.3s in, well inside the 5s busy
    // timeout the subprocess is configured with. The wide margin is for a
    // loaded machine: the release runs on a global dispatch queue that
    // parallel tests can starve past a shorter timeout.
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
        releaseLock.signal()
    }

    // This write blocks behind the GUI's held lock; the busy timeout
    // absorbs the wait rather than surfacing SQLITE_BUSY.
    try subprocessQueue.write { db in
        try db.execute(sql: insertMeetingSQL(id: "01SUBPROCESSMEETINGID00000"))
    }

    let count = try subprocessQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meetings") }
    #expect(count == 2)
}

/// The mirror case: contention that outlasts the busy timeout surfaces
/// GRDB's `DatabaseError` (SQLITE_BUSY) to the caller rather than hanging
/// or silently succeeding.
@Test func writeContentionOutlastingBusyTimeoutThrowsDatabaseError() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    try MigrationRegistrar.migrator.migrate(DatabaseQueue(path: path, configuration: makeConfiguration(busyTimeoutSeconds: 5)))

    let guiPool = try DatabasePool(path: path, configuration: makeConfiguration(busyTimeoutSeconds: 0.3))
    let subprocessQueue = try DatabaseQueue(path: path, configuration: makeConfiguration(busyTimeoutSeconds: 0.3))

    let lockAcquired = DispatchSemaphore(value: 0)
    let releaseLock = DispatchSemaphore(value: 0)

    let holderThread = Thread {
        try? guiPool.write { db in
            // `lockAcquired.signal()` is scoped to this `do` block via
            // `defer` so it fires whether the insert throws or succeeds —
            // if it only ran after a successful insert, a throw here would
            // leave the main thread's `lockAcquired.wait()` blocked forever.
            do {
                defer { lockAcquired.signal() }
                try db.execute(sql: insertMeetingSQL(id: "01HOLDERMEETINGID000000001"))
            }
            releaseLock.wait()
        }
    }
    holderThread.start()
    lockAcquired.wait()
    // The holder keeps the write lock until this test function returns —
    // well past the 0.3s busy timeout below, since `subprocessQueue.write`
    // itself blocks for the full timeout before throwing.
    defer { releaseLock.signal() }

    #expect(throws: DatabaseError.self) {
        try subprocessQueue.write { db in
            try db.execute(sql: insertMeetingSQL(id: "01SUBPROCESSMEETINGID00001"))
        }
    }
}

@Test func subprocessOpenerDoesNotMigrate() throws {
    let (directory, path) = makeTestDatabasePath()
    defer { try? FileManager.default.removeItem(at: directory) }

    let queue = try DatabasePoolFactory.makeQueue(path: path)
    let tableExists = try queue.read { db in try db.tableExists("meetings") }
    #expect(!tableExists, "a subprocess opener must not run migrations itself")
}
