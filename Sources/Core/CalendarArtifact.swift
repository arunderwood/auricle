/// The `calendar.json` cache-artifact contract (cache-artifact JSON dialect,
/// `Core/Codable+Dialects.swift`), written by the summarize stage for every
/// run. `degraded` is true when no usable event was found, in which case
/// `event` is absent from the encoded object rather than `null`.
///
/// Attendee emails are deliberately not part of the contract: nothing reads
/// them, and a field that is never written cannot leak.
public struct CalendarArtifact: Codable, Equatable, Sendable {
    public let degraded: Bool
    public let event: CalendarEventArtifact?

    enum CodingKeys: String, CodingKey {
        case degraded
        case event
    }

    public init(degraded: Bool, event: CalendarEventArtifact?) {
        self.degraded = degraded
        self.event = event
    }
}

public struct CalendarEventArtifact: Codable, Equatable, Sendable {
    /// Provider-namespaced, e.g. `google:<event id>`.
    public let eventID: String
    public let title: String
    /// ISO8601 UTC.
    public let start: String
    /// ISO8601 UTC.
    public let end: String
    public let attendees: [CalendarAttendeeArtifact]

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case title
        case start
        case end
        case attendees
    }

    public init(eventID: String, title: String, start: String, end: String, attendees: [CalendarAttendeeArtifact]) {
        self.eventID = eventID
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }
}

public struct CalendarAttendeeArtifact: Codable, Equatable, Sendable {
    /// Sanitized; absent when the invitation had no usable name.
    public let displayName: String?
    public let isSelf: Bool

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case isSelf = "is_self"
    }

    public init(displayName: String?, isSelf: Bool) {
        self.displayName = displayName
        self.isSelf = isSelf
    }
}
