import GRDB

/// GRDB record for `meetings` (architecture.md Decision 2.1) — one row per
/// captured meeting, the meeting's lifecycle anchor. `id` and `state` are
/// plain `String` at this level: `MeetingID` wrapping and any typed state
/// enum belong at the `StateStore` API boundary and in the state-machine
/// implementation (Story 1.5), not in the record itself.
public struct Meeting: Codable, Equatable, Sendable {
    public var id: String
    public var state: String
    public var createdAt: String
    public var updatedAt: String
    public var captureStartedAt: String?
    public var captureEndedAt: String?
    public var durationSeconds: Int?
    public var title: String?
    public var calendarEventID: String?
    public var vaultNotePath: String?
    public var audioCachePath: String?
    public var verifiedAt: String?
    public var retentionPolicy: String?

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case captureStartedAt = "capture_started_at"
        case captureEndedAt = "capture_ended_at"
        case durationSeconds = "duration_seconds"
        case title
        case calendarEventID = "calendar_event_id"
        case vaultNotePath = "vault_note_path"
        case audioCachePath = "audio_cache_path"
        case verifiedAt = "verified_at"
        case retentionPolicy = "retention_policy"
    }

    public init(
        id: String,
        state: String,
        createdAt: String,
        updatedAt: String,
        captureStartedAt: String? = nil,
        captureEndedAt: String? = nil,
        durationSeconds: Int? = nil,
        title: String? = nil,
        calendarEventID: String? = nil,
        vaultNotePath: String? = nil,
        audioCachePath: String? = nil,
        verifiedAt: String? = nil,
        retentionPolicy: String? = nil
    ) {
        self.id = id
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.captureStartedAt = captureStartedAt
        self.captureEndedAt = captureEndedAt
        self.durationSeconds = durationSeconds
        self.title = title
        self.calendarEventID = calendarEventID
        self.vaultNotePath = vaultNotePath
        self.audioCachePath = audioCachePath
        self.verifiedAt = verifiedAt
        self.retentionPolicy = retentionPolicy
    }
}

extension Meeting: FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "meetings"
}
