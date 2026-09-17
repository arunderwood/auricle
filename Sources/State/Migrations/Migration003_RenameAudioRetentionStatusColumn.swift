import GRDB

/// Migration #3: renames `telemetry.audio_retention_status_at_30d` to
/// `telemetry.audio_retention_status_at_snapshot`. The original name baked
/// the wedge-validation measurement window (30 days) directly into a
/// binding, migrated column identifier — a future change to that window
/// would otherwise require yet another rename migration just to keep the
/// name honest. The window itself now lives as
/// `TelemetrySnapshotPolicy.audioRetentionSnapshotDays`
/// (Sources/State/Telemetry.swift), the single place the (v1.1) periodic
/// backfill job will read it from. Forward-only (per Migration #2's own
/// precedent): migration #1's shipped SQL is never edited, so the rename
/// ships as its own migration appended after it.
enum Migration003RenameAudioRetentionStatusColumn {
    static let identifier = "003_rename_audio_retention_status_column"

    static func migrate(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE telemetry RENAME COLUMN audio_retention_status_at_30d TO audio_retention_status_at_snapshot;")
    }
}
