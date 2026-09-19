import CalendarInterface
import Foundation
@testable import GoogleCalendarSource
import Testing

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ minutes: Double) -> Date {
    base.addingTimeInterval(minutes * 60)
}

private func timed(
    _ id: String,
    from start: Double,
    to end: Double,
    status: String? = "confirmed",
    attendees: [CalendarAttendee] = [],
) -> GoogleEvent {
    GoogleEvent(id: id, status: status, title: "Event \(id)", attendees: attendees, start: at(start), end: at(end))
}

private func allDay(_ id: String) -> GoogleEvent {
    GoogleEvent(id: id, status: "confirmed", title: "All day \(id)", attendees: [], start: nil, end: nil)
}

@Test func matcherIncludesAnEventStartingExactlyAtTheInstant() {
    let match = EventMatcher.activeEvent(at: at(10), among: [timed("a", from: 10, to: 20)])

    #expect(match?.id.rawValue == "google:a")
}

@Test func matcherIncludesAnEventEndingExactlyAtTheInstant() {
    let match = EventMatcher.activeEvent(at: at(20), among: [timed("a", from: 10, to: 20)])

    #expect(match?.id.rawValue == "google:a")
}

@Test func matcherExcludesAnEventJustOutsideEitherBoundary() {
    let event = timed("a", from: 10, to: 20)

    #expect(EventMatcher.activeEvent(at: at(10).addingTimeInterval(-0.001), among: [event]) == nil)
    #expect(EventMatcher.activeEvent(at: at(20).addingTimeInterval(0.001), among: [event]) == nil)
}

@Test func matcherPrefersTheShortestOfNestedEvents() {
    let events = [timed("outer", from: 0, to: 120), timed("inner", from: 30, to: 60), timed("middle", from: 10, to: 90)]

    #expect(EventMatcher.activeEvent(at: at(45), among: events)?.id.rawValue == "google:inner")
}

@Test func matcherPrefersTheShorterEventWhenOneEndsExactlyAsAnotherStarts() {
    let events = [timed("long", from: 0, to: 60), timed("short", from: 60, to: 90)]

    #expect(EventMatcher.activeEvent(at: at(60), among: events)?.id.rawValue == "google:short")
}

@Test func matcherBreaksAnEqualDurationTieWithTheLaterStart() {
    let events = [timed("earlier", from: 0, to: 60), timed("later", from: 30, to: 90)]

    #expect(EventMatcher.activeEvent(at: at(45), among: events)?.id.rawValue == "google:later")
}

@Test func matcherBreaksAFullTieWithTheSmallerEventID() {
    let events = [timed("b", from: 0, to: 60), timed("a", from: 0, to: 60), timed("c", from: 0, to: 60)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events)?.id.rawValue == "google:a")
    #expect(EventMatcher.activeEvent(at: at(30), among: events.reversed())?.id.rawValue == "google:a")
}

@Test func matcherIgnoresAllDayEvents() {
    let events = [allDay("holiday"), timed("meeting", from: 0, to: 600)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events)?.id.rawValue == "google:meeting")
}

@Test func matcherReturnsNilWhenOnlyAllDayEventsAreAround() {
    #expect(EventMatcher.activeEvent(at: at(30), among: [allDay("holiday")]) == nil)
}

@Test func matcherIgnoresCancelledEvents() {
    let events = [timed("cancelled", from: 20, to: 40, status: "cancelled"), timed("kept", from: 0, to: 120)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events)?.id.rawValue == "google:kept")
}

@Test func matcherReturnsNilWhenOnlyCancelledEventsCoverTheInstant() {
    #expect(EventMatcher.activeEvent(at: at(30), among: [timed("x", from: 0, to: 60, status: "cancelled")]) == nil)
}

@Test func matcherReturnsNilWhenNothingCoversTheInstant() {
    let events = [timed("before", from: 0, to: 10), timed("after", from: 50, to: 60)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events) == nil)
    #expect(EventMatcher.activeEvent(at: at(30), among: []) == nil)
}

@Test func matcherCarriesTitleAttendeesAndTimesIntoTheCalendarEvent() throws {
    let attendees = [CalendarAttendee(email: "a@example.com", displayName: "Alice")]
    let match = try #require(EventMatcher.activeEvent(at: at(5), among: [timed("x", from: 0, to: 30, attendees: attendees)]))

    #expect(match.title == "Event x")
    #expect(match.attendees == attendees)
    #expect(match.start == at(0))
    #expect(match.end == at(30))
}

@Test func upcomingIncludesEventsStartingBetweenNowAndTheHorizonSortedByStart() {
    let events = [timed("late", from: 50, to: 60), timed("soon", from: 5, to: 15), timed("mid", from: 20, to: 25)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id.rawValue) == ["google:soon", "google:mid", "google:late"])
}

@Test func upcomingExcludesAnEventAlreadyRunning() {
    let events = [timed("running", from: -10, to: 30), timed("next", from: 10, to: 20)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id.rawValue) == ["google:next"])
}

@Test func upcomingIncludesBothBoundariesOfTheWindowAndExcludesJustBeyond() {
    let events = [timed("atNow", from: 0, to: 10), timed("atHorizon", from: 30, to: 40), timed("beyond", from: 30.5, to: 40)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 30 * 60, among: events)

    #expect(upcoming.map(\.id.rawValue) == ["google:atNow", "google:atHorizon"])
}

@Test func upcomingSkipsAllDayAndCancelledEvents() {
    let events = [allDay("holiday"), timed("gone", from: 5, to: 10, status: "cancelled"), timed("real", from: 6, to: 12)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id.rawValue) == ["google:real"])
}

@Test func upcomingBreaksAStartTieWithTheSmallerEventID() {
    let events = [timed("b", from: 5, to: 10), timed("a", from: 5, to: 20)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id.rawValue) == ["google:a", "google:b"])
}
