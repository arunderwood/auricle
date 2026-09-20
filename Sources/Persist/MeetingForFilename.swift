import Core

/// The sole input to `FilenameResolver.resolve(meeting:ordinal:)`. Every
/// field arrives pre-resolved by the caller — `captureDate` and
/// `captureTime24h` are already formatted in the user's local timezone at
/// capture time, never derived here.
public struct MeetingForFilename: Sendable, Equatable {
    public let meetingID: MeetingID
    /// Already formatted "YYYY-MM-DD", local time at capture, caller-resolved.
    public let captureDate: String
    /// Already formatted 24h "HHMM" (e.g. "0930", "1423"), local time at capture, caller-resolved.
    public let captureTime24h: String
    public let calendarEventTitle: String?
    /// Wikilink-formatted, e.g. "[[Ben]]" — includes self if self was a named participant.
    /// An entry may carry a path, alias, heading or block part (`[[People/Ben Smith|Ben]]`);
    /// the slug uses the alias when there is one, else the target's last path component.
    public let attendees: [String]
    /// Wikilink-formatted, e.g. "[[Jordan]]" — the config value described in epics.md's
    /// UX-DR42/FR58 (`self.wikilink`). An attendee is omitted from the `with-...` slug when
    /// its link identity equals this one's. A link's identity is its target's last path
    /// component, without any `|alias`, `#heading` or `^block` part, compared
    /// case-insensitively because Obsidian resolves links that way. Attendees that share an
    /// identity count once.
    public let selfWikilink: String?

    public init(
        meetingID: MeetingID,
        captureDate: String,
        captureTime24h: String,
        calendarEventTitle: String?,
        attendees: [String],
        selfWikilink: String?,
    ) {
        self.meetingID = meetingID
        self.captureDate = captureDate
        self.captureTime24h = captureTime24h
        self.calendarEventTitle = calendarEventTitle
        self.attendees = attendees
        self.selfWikilink = selfWikilink
    }
}
