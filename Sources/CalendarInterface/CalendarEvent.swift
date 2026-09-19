import Foundation

public struct CalendarEvent: Sendable, Equatable {
    /// Namespaced by provider, e.g. `google:<event id>`, so an id from one
    /// provider can never collide with another's.
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let attendees: [CalendarAttendee]

    public init(id: String, title: String, start: Date, end: Date, attendees: [CalendarAttendee]) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }
}

public struct CalendarAttendee: Sendable, Equatable {
    /// Carried so a source can identify who is who, but never forwarded to a
    /// prompt, a cache artifact or a note.
    public let email: String
    /// `nil` when the invitation carries no name.
    public let displayName: String?
    /// Whether this attendee is the calendar's owner.
    public let isSelf: Bool

    public init(email: String, displayName: String?, isSelf: Bool) {
        self.email = email
        self.displayName = displayName
        self.isSelf = isSelf
    }
}
