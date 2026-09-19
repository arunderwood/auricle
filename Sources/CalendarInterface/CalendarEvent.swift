import Foundation

/// A calendar event's identity, namespaced by its source as
/// `<namespace>:<event_id>` (AR-DATA-1) so ids from two sources can never
/// collide. A dedicated type, like `MeetingID`, so the compiler rejects a raw
/// `String` substituted by accident.
public struct CalendarEventID: Hashable, Sendable {
    public static let googleNamespace = "google"

    public let rawValue: String

    /// Wraps an already-namespaced string. Returns `nil` unless it has a
    /// non-empty namespace, a `:`, and a non-empty event id.
    public init?(namespacedID: String) {
        guard let separator = namespacedID.firstIndex(of: ":") else { return nil }
        let namespace = namespacedID[..<separator]
        let eventID = namespacedID[namespacedID.index(after: separator)...]
        guard !namespace.isEmpty, !eventID.isEmpty else { return nil }
        rawValue = namespacedID
    }

    /// Returns `nil` for an empty part or a namespace containing `:`.
    public init?(namespace: String, eventID: String) {
        guard !namespace.isEmpty, !namespace.contains(":"), !eventID.isEmpty else { return nil }
        rawValue = "\(namespace):\(eventID)"
    }

    public static func google(eventID: String) -> CalendarEventID? {
        CalendarEventID(namespace: googleNamespace, eventID: eventID)
    }

    public var namespace: String {
        String(rawValue[..<separatorIndex])
    }

    public var eventID: String {
        String(rawValue[rawValue.index(after: separatorIndex)...])
    }

    /// Both initializers guarantee a `:` is present.
    private var separatorIndex: String.Index {
        rawValue.firstIndex(of: ":")!
    }
}

extension CalendarEventID: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

public struct CalendarAttendee: Hashable, Sendable {
    public let email: String
    public let displayName: String?

    public init(email: String, displayName: String? = nil) {
        self.email = email
        self.displayName = displayName
    }
}

/// The slice of a calendar event the pipeline uses. Deliberately not
/// `Codable`: the on-disk `calendar.json` schema is a separate decision from
/// this in-memory shape.
public struct CalendarEvent: Hashable, Sendable {
    public let id: CalendarEventID
    /// Empty when the event has no title.
    public let title: String
    public let attendees: [CalendarAttendee]
    public let start: Date
    public let end: Date

    public init(id: CalendarEventID, title: String, attendees: [CalendarAttendee], start: Date, end: Date) {
        self.id = id
        self.title = title
        self.attendees = attendees
        self.start = start
        self.end = end
    }

    /// The names that may reach prompt assembly (NFR-Pr4), whitespace-trimmed.
    /// An attendee is skipped when they have no usable name: none, blank, or
    /// one that is really an address (some imported invites carry the email as
    /// the display name). A name is never derived from an email, because an
    /// address fragment in a prompt is exactly what that requirement forbids.
    public var attendeeDisplayNames: [String] {
        attendees.compactMap { attendee in
            guard let name = attendee.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            guard !name.contains("@"), name.caseInsensitiveCompare(attendee.email) != .orderedSame else {
                return nil
            }
            return name
        }
    }
}
