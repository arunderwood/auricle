import CalendarInterface
import Foundation

/// Pure event selection over already-fetched events, kept free of HTTP so the
/// tie-breaking rules are testable directly.
enum EventMatcher {
    private struct TimedEvent {
        let event: GoogleEvent
        let start: Date
        let end: Date

        var duration: TimeInterval {
            end.timeIntervalSince(start)
        }
    }

    /// The event that covers `instant`, both ends inclusive. All-day and
    /// cancelled events never match. Among several candidates the shortest
    /// wins, then the later start, then the smaller event id, so the same
    /// input always yields the same event.
    static func activeEvent(at instant: Date, among events: [GoogleEvent]) -> CalendarEvent? {
        let covering = events.compactMap { event -> TimedEvent? in
            guard !event.isCancelled, let start = event.start, let end = event.end else { return nil }
            guard start <= instant, instant <= end else { return nil }
            return TimedEvent(event: event, start: start, end: end)
        }

        let best = covering.min { lhs, rhs in
            if lhs.duration != rhs.duration {
                return lhs.duration < rhs.duration
            }
            if lhs.start != rhs.start {
                return lhs.start > rhs.start
            }
            return lhs.event.id < rhs.event.id
        }
        return best?.event.calendarEvent
    }

    /// Timed, non-cancelled events that start in `[now, now + window]`,
    /// soonest first (ties by event id). An event that began before `now` is
    /// excluded even though it is still running.
    static func upcomingEvents(from now: Date, window: TimeInterval, among events: [GoogleEvent]) -> [CalendarEvent] {
        let horizon = now.addingTimeInterval(window)
        return events
            .compactMap { event -> (event: GoogleEvent, start: Date)? in
                guard !event.isCancelled, let start = event.start, start >= now, start <= horizon else { return nil }
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
