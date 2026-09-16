import GRDB

/// The single place migrations are registered, in order (AR-DATA-5).
/// Migrations are forward-only: a shipped migration's identifier and body
/// are never edited or removed, and a schema change always ships as a new
/// migration appended after the last one (architecture.md:842).
enum MigrationRegistrar {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration(Migration001Initial.identifier, migrate: Migration001Initial.migrate)
        return migrator
    }
}
