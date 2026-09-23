import Foundation
import GRDB
@testable import State
import Testing

/// A database migrated only to #4 and holding a real `meetings` row, upgraded
/// in place by migration #5. The row keeps its values and reads NULL in the
/// added column.
@Test func migrationFiveAddsANullableCaptureTimeZoneLeavingAnExistingRowNull() throws {
    let queue = try DatabaseQueue()
    var migrationsOneToFourOnly = DatabaseMigrator()
    migrationsOneToFourOnly.registerMigration(Migration001Initial.identifier, migrate: Migration001Initial.migrate)
    migrationsOneToFourOnly.registerMigration(
        Migration002StageEventsMetadataSchemaVersion.identifier,
        migrate: Migration002StageEventsMetadataSchemaVersion.migrate,
    )
    migrationsOneToFourOnly.registerMigration(
        Migration003RenameAudioRetentionStatusColumn.identifier,
        migrate: Migration003RenameAudioRetentionStatusColumn.migrate,
    )
    migrationsOneToFourOnly.registerMigration(
        Migration004TelemetryGroundingAndPromptSetHash.identifier,
        migrate: Migration004TelemetryGroundingAndPromptSetHash.migrate,
    )
    try migrationsOneToFourOnly.migrate(queue)
    #expect(try captureTimeZoneColumn(in: queue.read { db in try db.columns(in: "meetings") }) == nil)

    try queue.write { db in
        try db.execute(
            sql: """
            INSERT INTO meetings (id, state, created_at, updated_at, capture_started_at)
            VALUES ('01PREMIGRATION5MEETINGID0', 'captured', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
            """,
        )
    }

    try MigrationRegistrar.migrator.migrate(queue)

    let column = try #require(captureTimeZoneColumn(in: queue.read { db in try db.columns(in: "meetings") }))
    #expect(column.type.uppercased() == "TEXT")
    #expect(!column.isNotNull)

    let meeting = try #require(try queue.read { db in try Meeting.fetchOne(db, key: "01PREMIGRATION5MEETINGID0") })
    #expect(meeting.state == "captured")
    #expect(meeting.captureStartedAt == "2026-01-01T00:00:00Z")
    #expect(meeting.captureTimeZone == nil)
}

private func captureTimeZoneColumn(in columns: [ColumnInfo]) -> ColumnInfo? {
    columns.first { $0.name == "capture_time_zone" }
}
