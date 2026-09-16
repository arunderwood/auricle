import GRDB

/// Migration #2: `stage_events.metadata_schema_version`, the column
/// architecture.md's Decision 4.5 describes as part of "the schema locked
/// in Decision 2.1" but Decision 2.1's own `CREATE TABLE stage_events` SQL
/// (verbatim-copied into migration #1) never actually included — a
/// pre-existing inconsistency between two architecture.md sections that
/// predates this migration. Forward-only (AR-DATA-5): migration #1's
/// shipped SQL is never edited, so the column arrives as its own migration
/// appended after it. `DEFAULT 1` covers any row inserted by SQL outside
/// `StageEventLogger`'s typed path (there is none in production, but the
/// column must still be well-defined for one); `StageEventLogger` itself
/// sets the value explicitly on every insert rather than relying on the
/// default.
enum Migration002StageEventsMetadataSchemaVersion {
    static let identifier = "002_stage_events_metadata_schema_version"

    static func migrate(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE stage_events ADD COLUMN metadata_schema_version INTEGER DEFAULT 1;")
    }
}
