import CalendarInterface
import Foundation

/// Pure event selection over already-fetched events, kept free of HTTP so the
/// tie-breaking rules are testable directly.
enum EventMatcher {
    /// How long before an event's start a recording may begin and still belong
    /// to it. People start recording as they join, not on the minute, and a
    /// meeting that was running until then would otherwise be the only match.
    static let leadIn: TimeInterval = 5 * 60

    /// Where an event sits relative to the instant, in the order a recording
    /// most plausibly belongs to it. A recording that begins just ahead of an
    /// event is far likelier to be for that event than for an earlier one still
    /// on the calendar, and an event that ends the very instant another starts
    /// has finished.
    private enum Phase: Int, Comparable {
        case upcoming
        case running
        case justEnded

        static func < (lhs: Phase, rhs: Phase) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    private struct Candidate {
        let event: GoogleEvent
        let start: Date
        let end: Date
        let phase: Phase

        var duration: TimeInterval {
            end.timeIntervalSince(start)
        }
    }

    /// The event a recording that began at `instant` most plausibly belongs to.
    /// A candidate covers `instant` (both ends inclusive) or starts within
    /// `leadIn` after it. All-day, cancelled and declined events and non-meeting
    /// event types never match.
    ///
    /// Ranking, so the same input always yields the same event:
    /// 1. Events the owner did not mark free come before ones they did.
    /// 2. An event about to start, then one in progress, then one that ends at
    ///    exactly `instant`.
    /// 3. Among upcoming events, the soonest start.
    /// 4. The shortest, so a specific meeting beats the broad block around it.
    /// 5. The later start, then the smaller event id.
    static func activeEvent(at instant: Date, among events: [GoogleEvent]) -> CalendarEvent? {
        let best = events
            .compactMap { candidate($0, at: instant) }
            .min(by: precedes)
        return best?.event.calendarEvent
    }

    private static func candidate(_ event: GoogleEvent, at instant: Date) -> Candidate? {
        guard event.isMeetingCandidate, let start = event.start, let end = event.end else { return nil }
        guard start.addingTimeInterval(-leadIn) <= instant, instant <= end else { return nil }

        let phase: Phase = if instant < start {
            .upcoming
        } else if instant == end, start < end {
            .justEnded
        } else {
            .running
        }
        return Candidate(event: event, start: start, end: end, phase: phase)
    }

    private static func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.event.isFree != rhs.event.isFree {
            return !lhs.event.isFree
        }
        if lhs.phase != rhs.phase {
            return lhs.phase < rhs.phase
        }
        if lhs.phase == .upcoming, lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        if lhs.duration != rhs.duration {
            return lhs.duration < rhs.duration
        }
        if lhs.start != rhs.start {
            return lhs.start > rhs.start
        }
        return lhs.event.id < rhs.event.id
    }

    /// Timed events that could be a meeting and start in `[now, now + window]`,
    /// soonest first (ties by event id). An event that began before `now` is
    /// excluded even though it is still running.
    static func upcomingEvents(from now: Date, window: TimeInterval, among events: [GoogleEvent]) -> [CalendarEvent] {
        let horizon = now.addingTimeInterval(window)
        return events
            .compactMap { event -> (event: GoogleEvent, start: Date)? in
                guard event.isMeetingCandidate, let start = event.start, start >= now, start <= horizon else { return nil }
                return (event, start)
            }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start {
                    return lhs.start < rhs.start
                }
                return lhs.event.id < rhs.event.id
            }
            .compactMap(\.event.calendarEvent)
    }
}
