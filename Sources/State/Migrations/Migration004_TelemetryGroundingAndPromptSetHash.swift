import GRDB

/// Migration #4: the two summarize-stage columns on `telemetry`.
/// `grounding_method` holds `citations` or `substring`, the strategy that
/// answered. `summarization_prompt_set_hash` holds the lowercase-hex SHA-256 of
/// the prompt files that strategy's mode resolved, so a stored hash can explain
/// why two notes summarized differently while prompts are user-editable.
/// Both are nullable TEXT: a `telemetry` row is filled in by several stages, so
/// it has no value in either column until the summarize stage has run for that
/// meeting. Forward-only: migration #1's SQL is never edited, so a schema change
/// is always a new migration appended after the last one.
enum Migration004TelemetryGroundingAndPromptSetHash {
    static let identifier = "004_telemetry_grounding_method_and_prompt_set_hash"

    static func migrate(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE telemetry ADD COLUMN grounding_method TEXT;")
        try db.execute(sql: "ALTER TABLE telemetry ADD COLUMN summarization_prompt_set_hash TEXT;")
    }
}
