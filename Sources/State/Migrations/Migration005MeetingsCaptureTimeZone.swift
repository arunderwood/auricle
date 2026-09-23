import GRDB

/// Migration #5: `meetings.capture_time_zone`, the IANA identifier of the zone
/// the Mac was in when a live capture started. `capture_started_at` is UTC, so
/// without it a note's local date would follow whatever zone the pipeline
/// happens to run in. Nullable TEXT: an imported recording has no capture zone,
/// and every row that predates this migration reads NULL, which readers treat
/// as "use the current zone". Forward-only, appended after the last migration.
enum Migration005MeetingsCaptureTimeZone {
    static let identifier = "005_meetings_capture_time_zone"

    static func migrate(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE meetings ADD COLUMN capture_time_zone TEXT;")
    }
}
