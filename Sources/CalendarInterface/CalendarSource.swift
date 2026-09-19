import Foundation

/// A calendar the app can ask about the meeting a capture falls inside
/// (FR51, FR52). Protocol-only: the concrete source is chosen by a
/// composition root, and callers depend on this interface alone.
public protocol CalendarSource: Sendable {
    /// Runs whatever interactive consent the source needs and persists the
    /// resulting credential. Throws `CalendarError.authorizationFailed` when
    /// the user does not complete it.
    func authorize() async throws

    /// The single event that covers `instant`, or `nil` when none does. When
    /// several overlap, the most specific one (the shortest) wins.
    func fetchActiveEvent(at instant: Date) async throws -> CalendarEvent?

    /// Events that start between now and `window` seconds from now, soonest
    /// first. An event already in progress is not included.
    func upcomingEvents(in window: TimeInterval) async throws -> [CalendarEvent]
}
