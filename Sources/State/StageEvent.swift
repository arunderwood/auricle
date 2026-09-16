import GRDB

/// GRDB record for `stage_events` (architecture.md Decision 2.1) — the
/// append-only stage event log, replayable for audit and forensic crash
/// analysis. `id` is `nil` until insertion assigns the autoincremented
/// rowid (`didInsert`).
public struct StageEvent: Codable, Equatable, Sendable {
    public var id: Int64?
    public var meetingID: String
    public var stage: String
    public var event: String
    public var occurredAt: String
    public var durationMS: Int?
    public var errorMessage: String?
    public var metadataJSON: String?
    public var metadataSchemaVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case meetingID = "meeting_id"
        case stage
        case event
        case occurredAt = "occurred_at"
        case durationMS = "duration_ms"
        case errorMessage = "error_message"
        case metadataJSON = "metadata_json"
        case metadataSchemaVersion = "metadata_schema_version"
    }

    public init(
        id: Int64? = nil,
        meetingID: String,
        stage: String,
        event: String,
        occurredAt: String,
        durationMS: Int? = nil,
        errorMessage: String? = nil,
        metadataJSON: String? = nil,
        metadataSchemaVersion: Int? = nil
    ) {
        self.id = id
        self.meetingID = meetingID
        self.stage = stage
        self.event = event
        self.occurredAt = occurredAt
        self.durationMS = durationMS
        self.errorMessage = errorMessage
        self.metadataJSON = metadataJSON
        self.metadataSchemaVersion = metadataSchemaVersion
    }
}

extension StageEvent: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "stage_events"

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
