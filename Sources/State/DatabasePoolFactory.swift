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
    /// exist yet.
    static func productionDatabasePath() throws -> String {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true,
        )
        let directory = appSupport.appendingPathComponent("com.auricle.app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("auricle.sqlite3").path
    }

    /// GUI opener: concurrent reads alongside the GUI's own writes.
    static func makePool(path: String) throws -> DatabasePool {
        try DatabasePool(path: path, configuration: baseConfiguration())
    }

    /// Subprocess opener: a single writer: subprocesses don't need read
    /// concurrency, and their transactions are short (<50ms).
    static func makeQueue(path: String) throws -> DatabaseQueue {
        try DatabaseQueue(path: path, configuration: baseConfiguration())
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
}
