import Foundation

/// A read-only view of the user's calendar (AR-PAT-7). The summarize stage
/// consumes it through this protocol only, so it never learns which provider
/// answers or how that provider authenticates.
public protocol CalendarSource: Sendable {
    /// Runs the provider's interactive sign-in. Never called from the
    /// summarize stage, which must not prompt: a source that is not
    /// authorized reports `CalendarError.authorizationExpired` from the
    /// fetch calls instead.
    func authorize() async throws

    /// The event in progress at `date`, or `nil` when none matches. When
    /// several overlap, the source picks the one that fits best.
    ///
    /// The caller sets no deadline. An implementation must bound its own
    /// request time and throw `CalendarError.unreachable` when that bound
    /// expires: a caller cannot preempt an await that never checks for
    /// cancellation, so a lookup that never returns would hang the meeting.
    func fetchActiveEvent(at date: Date) async throws -> CalendarEvent?

    /// Events starting within `window` seconds from now.
    func upcomingEvents(in window: TimeInterval) async throws -> [CalendarEvent]
}
