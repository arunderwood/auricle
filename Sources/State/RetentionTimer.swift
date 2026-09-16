import GRDB

/// GRDB record for `retention_timers` (architecture.md Decision 2.1) — one
/// row per meeting once verification fires, queuing the eventual audio
/// deletion.
public struct RetentionTimer: Codable, Equatable, Sendable {
    public var meetingID: String
    public var armedAt: String
    public var firesAt: String
    public var lastRemindedAt: String?
    public var status: String

    enum CodingKeys: String, CodingKey {
        case meetingID = "meeting_id"
        case armedAt = "armed_at"
        case firesAt = "fires_at"
        case lastRemindedAt = "last_reminded_at"
        case status
    }

    public init(
        meetingID: String,
        armedAt: String,
        firesAt: String,
        lastRemindedAt: String? = nil,
        status: String = "pending"
    ) {
        self.meetingID = meetingID
        self.armedAt = armedAt
        self.firesAt = firesAt
        self.lastRemindedAt = lastRemindedAt
        self.status = status
    }
}

extension RetentionTimer: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "retention_timers"
}
