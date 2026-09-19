import CalendarInterface
import Core
import Foundation

/// One entry of a Calendar API `events.list` response, reduced to what the
/// source needs. `start`/`end` are `nil` for an all-day event: Google reports
/// it as a bare `date`, which the source does not request, so no `dateTime`
/// arrives.
struct GoogleEvent: Equatable, Sendable {
    /// Calendar entries that block time without being a meeting anyone joins.
    private static let nonMeetingTypes: Set<String> = ["focusTime", "outOfOffice", "workingLocation"]

    let id: String
    let status: String?
    let title: String
    let attendees: [CalendarAttendee]
    let start: Date?
    let end: Date?
    let eventType: String?
    /// `"transparent"` when the owner marked the event as not blocking their time.
    let transparency: String?
    /// The signed-in user's own reply, taken from the attendee Google flags
    /// `self`. `nil` when the event has no attendee list (one the user made
    /// for themselves) or the reply was not requested.
    let selfResponseStatus: String?

    init(
        id: String,
        status: String?,
        title: String,
        attendees: [CalendarAttendee],
        start: Date?,
        end: Date?,
        eventType: String? = nil,
        transparency: String? = nil,
        selfResponseStatus: String? = nil,
    ) {
        self.id = id
        self.status = status
        self.title = title
        self.attendees = attendees
        self.start = start
        self.end = end
        self.eventType = eventType
        self.transparency = transparency
        self.selfResponseStatus = selfResponseStatus
    }

    var isCancelled: Bool {
        status == "cancelled"
    }

    var isDeclined: Bool {
        selfResponseStatus == "declined"
    }

    var isFree: Bool {
        transparency == "transparent"
    }

    /// Whether the event could be the meeting a recording belongs to. An event
    /// the user declined is not one they attend, and a focus, out-of-office or
    /// working-location block covers the hours around real meetings.
    var isMeetingCandidate: Bool {
        guard !isCancelled, !isDeclined else { return false }
        guard let eventType else { return true }
        return !Self.nonMeetingTypes.contains(eventType)
    }

    /// `nil` when the event cannot be a timed `CalendarEvent`: all-day, or
    /// without a usable id.
    var calendarEvent: CalendarEvent? {
        guard let start, let end, !id.isEmpty else { return nil }
        return CalendarEvent(id: Self.idPrefix + id, title: title, start: start, end: end, attendees: attendees)
    }

    /// Namespaces the id so it can never collide with another provider's.
    static let idPrefix = "google:"
}

/// Wire shape of `events.list`, with the `fields` mask
/// `GoogleCalendarSource` requests. Decoding is deliberately strict about a
/// present-but-unparseable `dateTime`: a timed event whose time can't be read
/// would otherwise silently vanish from matching.
struct GoogleEventList: Decodable {
    let events: [GoogleEvent]

    private enum CodingKeys: String, CodingKey {
        case items
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let wireEvents = try container.decodeIfPresent([WireEvent].self, forKey: .items) ?? []
        events = wireEvents.map(\.event)
    }
}

private struct WireEvent: Decodable {
    let id: String
    let status: String?
    let summary: String?
    let attendees: [WireAttendee]?
    let start: WireTime?
    let end: WireTime?
    let eventType: String?
    let transparency: String?

    var event: GoogleEvent {
        GoogleEvent(
            id: id,
            status: status,
            title: summary ?? "",
            attendees: (attendees ?? []).map {
                CalendarAttendee(email: $0.email ?? "", displayName: $0.displayName, isSelf: $0.isSelf ?? false)
            },
            start: start?.dateTime,
            end: end?.dateTime,
            eventType: eventType,
            transparency: transparency,
            selfResponseStatus: attendees?.first { $0.isSelf == true }?.responseStatus,
        )
    }
}

private struct WireAttendee: Decodable {
    let email: String?
    let displayName: String?
    let isSelf: Bool?
    let responseStatus: String?

    private enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case isSelf = "self"
        case responseStatus
    }
}

private struct WireTime: Decodable {
    let dateTime: Date?

    private enum CodingKeys: String, CodingKey {
        case dateTime
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let raw = try container.decodeIfPresent(String.self, forKey: .dateTime) else {
            dateTime = nil
            return
        }
        guard let parsed = ISO8601UTC.date(from: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .dateTime, in: container, debugDescription: "not an RFC 3339 date-time")
        }
        dateTime = parsed
    }
}
