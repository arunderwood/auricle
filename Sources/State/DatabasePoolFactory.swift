import Foundation
import GRDB

/// Resolves the on-disk database location and opens the connection type each
/// process needs (architecture.md Decision 2.1, AR-DATA-2): the GUI wants
/// concurrent reads alongside its own writes (`DatabasePool`); a subprocess
/// is a single short-lived writer with no read-concurrency need
/// (`DatabaseQueue`).
enum DatabasePoolFactory {
    /// `~/Library/Application Support/com.auricle.app/auricle.sqlite3`,
    /// creating the containing directory on first use if it doesn't
    /// exist yet. Only the GUI opener may use this: it is the one process
    /// that creates and migrates the database.
    static func productionDatabasePath() throws -> String {
        let url = try productionDatabaseURL(createAppSupportDirectory: true)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url.path
    }

    /// The same location as `productionDatabasePath()`, created nowhere: the
    /// path a subprocess or a status command probes, where an absent file
    /// or directory means "the app has not run yet", not "make one".
    static func lookUpProductionDatabasePath() throws -> String {
        try productionDatabaseURL(createAppSupportDirectory: false).path
    }

    private static func productionDatabaseURL(createAppSupportDirectory: Bool) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createAppSupportDirectory,
        )
        return appSupport
            .appendingPathComponent("com.auricle.app", isDirectory: true)
            .appendingPathComponent("auricle.sqlite3")
    }

    /// GUI opener: concurrent reads alongside the GUI's own writes.
    static func makePool(path: String) throws -> DatabasePool {
        try DatabasePool(path: path, configuration: baseConfiguration())
    }

    /// Subprocess opener: a single writer: subprocesses don't need read
    /// concurrency, and their transactions are short (<50ms).
    ///
    /// Callers verify the schema first (`makeVerifiedQueue`): this
    /// opener creates a missing file and sets WAL on an existing one, neither
    /// of which a process that never migrates may do to a database it would
    /// then refuse.
    static func makeQueue(path: String) throws -> DatabaseQueue {
        try DatabaseQueue(path: path, configuration: baseConfiguration())
    }

    /// Opens `path` and proves it holds exactly the schema this binary was
    /// built against, throwing a typed `StateStoreError` for a missing file, an
    /// unmigrated or partly migrated one, and one a newer binary has migrated.
    /// A rejected file's contents are left as they were: the file is never
    /// created and no journal mode is changed.
    ///
    /// The connection is an ordinary one, not `SQLITE_OPEN_READONLY`: a
    /// read-only connection to a WAL database cannot open it when no `-wal` and
    /// `-shm` files exist, which is how a database is left once its last
    /// connection has closed cleanly. It may therefore leave empty sidecar
    /// files behind, as any reader of a WAL database does.
    ///
    /// A newer schema is checked first because `hasCompletedMigrations`
    /// ignores identifiers this binary does not register, so it is true for
    /// a database that is ahead of it.
    static func makeVerifiedQueue(path: String) throws -> DatabaseQueue {
        guard FileManager.default.fileExists(atPath: path) else {
            throw StateStoreError.databaseNotFound
        }
        let queue = try DatabaseQueue(path: path, configuration: verificationConfiguration())
        let migrator = MigrationRegistrar.migrator
        try queue.read { db in
            if try migrator.hasBeenSuperseded(db) {
                throw StateStoreError.schemaSuperseded
            }
            guard try migrator.hasCompletedMigrations(db) else {
                throw StateStoreError.schemaNotMigrated
            }
        }
        return queue
    }

    /// Shared by every opener (AR-DATA-2): a 5s busy timeout absorbs the
    /// window where GUI and subprocess writers briefly overlap; foreign keys
    /// on for the tables' `ON DELETE CASCADE` integrity.
    ///
    /// `journalMode = .wal` is set explicitly rather than left at GRDB's
    /// default, because that default treats `DatabasePool` and
    /// `DatabaseQueue` differently: `DatabasePool` switches to WAL on its
    /// own, but `DatabaseQueue`'s default leaves the journal mode untouched
    /// at connection-open time. Setting it here makes both openers request
    /// WAL the same way, rather than depending on a `DatabaseQueue`
    /// subprocess merely inheriting WAL from the file's sticky header.
    private static func baseConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5.0)
        configuration.foreignKeysEnabled = true
        configuration.journalMode = .wal
        return configuration
    }

    /// Leaves `journalMode` alone rather than sharing `baseConfiguration()`:
    /// setting it would change the journal mode of a file this connection may
    /// be about to reject.
    private static func verificationConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(5.0)
        return configuration
    }
}
