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
    eventType: String? = nil,
    transparency: String? = nil,
    selfResponseStatus: String? = nil,
) -> GoogleEvent {
    GoogleEvent(
        id: id,
        status: status,
        title: "Event \(id)",
        attendees: attendees,
        start: at(start),
        end: at(end),
        eventType: eventType,
        transparency: transparency,
        selfResponseStatus: selfResponseStatus,
    )
}

private func allDay(_ id: String) -> GoogleEvent {
    GoogleEvent(id: id, status: "confirmed", title: "All day \(id)", attendees: [], start: nil, end: nil)
}

@Test func matcherIncludesAnEventStartingExactlyAtTheInstant() {
    let match = EventMatcher.activeEvent(at: at(10), among: [timed("a", from: 10, to: 20)])

    #expect(match?.id == "google:a")
}

@Test func matcherIncludesAnEventEndingExactlyAtTheInstant() {
    let match = EventMatcher.activeEvent(at: at(20), among: [timed("a", from: 10, to: 20)])

    #expect(match?.id == "google:a")
}

@Test func matcherExcludesAnEventJustPastItsEnd() {
    let event = timed("a", from: 10, to: 20)

    #expect(EventMatcher.activeEvent(at: at(20).addingTimeInterval(0.001), among: [event]) == nil)
}

@Test func matcherPrefersTheShortestOfNestedEvents() {
    let events = [timed("outer", from: 0, to: 120), timed("inner", from: 30, to: 60), timed("middle", from: 10, to: 90)]

    #expect(EventMatcher.activeEvent(at: at(45), among: events)?.id == "google:inner")
}

@Test func matcherPrefersTheShorterEventEvenWhenTheLongerOneStartedLater() {
    let events = [timed("longLater", from: 15, to: 120), timed("shortEarlier", from: 0, to: 30)]

    #expect(EventMatcher.activeEvent(at: at(20), among: events)?.id == "google:shortEarlier")
}

@Test func matcherTreatsAnEventEndingAtTheInstantAnotherStartsAsFinished() {
    let events = [timed("endingShort", from: 30, to: 60), timed("startingLong", from: 60, to: 150)]

    #expect(EventMatcher.activeEvent(at: at(60), among: events)?.id == "google:startingLong")
    #expect(EventMatcher.activeEvent(at: at(60), among: events.reversed())?.id == "google:startingLong")
}

@Test func matcherStillMatchesAnEventEndingAtTheInstantWhenNothingElseDoes() {
    let events = [timed("ending", from: 30, to: 60), timed("muchLater", from: 120, to: 150)]

    #expect(EventMatcher.activeEvent(at: at(60), among: events)?.id == "google:ending")
}

// MARK: - Lead-in

@Test func matcherMatchesAnEventThatStartsWithinTheLeadInAfterTheInstant() {
    let event = timed("upcoming", from: 10, to: 70)

    #expect(EventMatcher.leadIn == 5 * 60)
    #expect(EventMatcher.activeEvent(at: at(5), among: [event])?.id == "google:upcoming")
    #expect(EventMatcher.activeEvent(at: at(9.99), among: [event])?.id == "google:upcoming")
}

@Test func matcherIgnoresAnEventThatStartsJustBeyondTheLeadIn() {
    let event = timed("upcoming", from: 10, to: 70)

    #expect(EventMatcher.activeEvent(at: at(5).addingTimeInterval(-0.001), among: [event]) == nil)
}

@Test func matcherPrefersTheUpcomingEventOverAnEarlierOneStillRunning() {
    let events = [timed("running", from: 0, to: 60), timed("upcoming", from: 60, to: 120)]

    #expect(EventMatcher.activeEvent(at: at(59.5), among: events)?.id == "google:upcoming")
    #expect(EventMatcher.activeEvent(at: at(59.5), among: events.reversed())?.id == "google:upcoming")
}

@Test func matcherPrefersTheUpcomingEventEvenWhenTheRunningOneIsShorter() {
    let events = [timed("runningShort", from: 50, to: 60), timed("upcomingLong", from: 60, to: 180)]

    #expect(EventMatcher.activeEvent(at: at(58), among: events)?.id == "google:upcomingLong")
}

@Test func matcherKeepsTheRunningEventWhenTheNextOneIsBeyondTheLeadIn() {
    let events = [timed("running", from: 0, to: 60), timed("later", from: 60, to: 120)]

    #expect(EventMatcher.activeEvent(at: at(50), among: events)?.id == "google:running")
}

@Test func matcherPrefersTheSoonestOfSeveralUpcomingEventsWhateverTheirLength() {
    let events = [timed("soonLong", from: 57, to: 180), timed("laterShort", from: 59, to: 60)]

    #expect(EventMatcher.activeEvent(at: at(55), among: events)?.id == "google:soonLong")
}

@Test func matcherBreaksAnUpcomingStartTieWithTheShorterThenTheSmallerID() {
    let events = [timed("b", from: 60, to: 90), timed("a", from: 60, to: 90), timed("short", from: 60, to: 70)]

    #expect(EventMatcher.activeEvent(at: at(58), among: events)?.id == "google:short")
    #expect(EventMatcher.activeEvent(at: at(58), among: Array(events.dropLast()))?.id == "google:a")
}

// MARK: - Declined, non-meeting and free events

@Test func matcherIgnoresAnEventTheUserDeclined() {
    let events = [timed("declined", from: 20, to: 40, selfResponseStatus: "declined"), timed("kept", from: 0, to: 120)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events)?.id == "google:kept")
    #expect(EventMatcher.activeEvent(at: at(30), among: [events[0]]) == nil)
}

@Test(arguments: ["accepted", "tentative", "needsAction"])
func matcherKeepsAnEventTheUserHasNotDeclined(response: String) {
    let event = timed("a", from: 0, to: 60, selfResponseStatus: response)

    #expect(EventMatcher.activeEvent(at: at(30), among: [event])?.id == "google:a")
}

@Test(arguments: ["focusTime", "outOfOffice", "workingLocation"])
func matcherIgnoresNonMeetingEventTypes(type: String) {
    let events = [timed("block", from: 20, to: 40, eventType: type), timed("meeting", from: 0, to: 120)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events)?.id == "google:meeting")
    #expect(EventMatcher.activeEvent(at: at(30), among: [events[0]]) == nil)
}

@Test(arguments: [nil, "default", "fromGmail"])
func matcherKeepsOrdinaryEventTypes(type: String?) {
    let event = timed("a", from: 0, to: 60, eventType: type)

    #expect(EventMatcher.activeEvent(at: at(30), among: [event])?.id == "google:a")
}

@Test func matcherPrefersABusyEventOverAFreeOneEvenWhenTheFreeOneIsShorter() {
    let events = [timed("free", from: 10, to: 20, transparency: "transparent"), timed("busy", from: 0, to: 60)]

    #expect(EventMatcher.activeEvent(at: at(15), among: events)?.id == "google:busy")
}

@Test func matcherStillMatchesAFreeEventWhenNothingBusyDoes() {
    let events = [timed("free", from: 10, to: 20, transparency: "transparent")]

    #expect(EventMatcher.activeEvent(at: at(15), among: events)?.id == "google:free")
}

@Test func matcherTreatsOpaqueAndMissingTransparencyAsBusy() {
    let events = [timed("opaque", from: 0, to: 60, transparency: "opaque"), timed("unset", from: 0, to: 30)]

    #expect(EventMatcher.activeEvent(at: at(15), among: events)?.id == "google:unset")
}

@Test func matcherBreaksAnEqualDurationTieWithTheLaterStart() {
    let events = [timed("earlier", from: 0, to: 60), timed("later", from: 30, to: 90)]

    #expect(EventMatcher.activeEvent(at: at(45), among: events)?.id == "google:later")
}

@Test func matcherBreaksAFullTieWithTheSmallerEventID() {
    let events = [timed("b", from: 0, to: 60), timed("a", from: 0, to: 60), timed("c", from: 0, to: 60)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events)?.id == "google:a")
    #expect(EventMatcher.activeEvent(at: at(30), among: events.reversed())?.id == "google:a")
}

@Test func matcherIgnoresAllDayEvents() {
    let events = [allDay("holiday"), timed("meeting", from: 0, to: 600)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events)?.id == "google:meeting")
}

@Test func matcherReturnsNilWhenOnlyAllDayEventsAreAround() {
    #expect(EventMatcher.activeEvent(at: at(30), among: [allDay("holiday")]) == nil)
}

@Test func matcherIgnoresCancelledEvents() {
    let events = [timed("cancelled", from: 20, to: 40, status: "cancelled"), timed("kept", from: 0, to: 120)]

    #expect(EventMatcher.activeEvent(at: at(30), among: events)?.id == "google:kept")
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
    let attendees = [CalendarAttendee(email: "a@example.com", displayName: "Alice", isSelf: false)]
    let match = try #require(EventMatcher.activeEvent(at: at(5), among: [timed("x", from: 0, to: 30, attendees: attendees)]))

    #expect(match.title == "Event x")
    #expect(match.attendees == attendees)
    #expect(match.start == at(0))
    #expect(match.end == at(30))
}

@Test func upcomingIncludesEventsStartingBetweenNowAndTheHorizonSortedByStart() {
    let events = [timed("late", from: 50, to: 60), timed("soon", from: 5, to: 15), timed("mid", from: 20, to: 25)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id) == ["google:soon", "google:mid", "google:late"])
}

@Test func upcomingExcludesAnEventAlreadyRunning() {
    let events = [timed("running", from: -10, to: 30), timed("next", from: 10, to: 20)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id) == ["google:next"])
}

@Test func upcomingIncludesBothBoundariesOfTheWindowAndExcludesJustBeyond() {
    let events = [timed("atNow", from: 0, to: 10), timed("atHorizon", from: 30, to: 40), timed("beyond", from: 30.5, to: 40)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 30 * 60, among: events)

    #expect(upcoming.map(\.id) == ["google:atNow", "google:atHorizon"])
}

@Test func upcomingSkipsAllDayAndCancelledEvents() {
    let events = [allDay("holiday"), timed("gone", from: 5, to: 10, status: "cancelled"), timed("real", from: 6, to: 12)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id) == ["google:real"])
}

@Test func upcomingSkipsDeclinedAndNonMeetingEvents() {
    let events = [
        timed("declined", from: 5, to: 10, selfResponseStatus: "declined"),
        timed("focus", from: 6, to: 12, eventType: "focusTime"),
        timed("real", from: 7, to: 14, selfResponseStatus: "accepted"),
    ]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id) == ["google:real"])
}

@Test func upcomingBreaksAStartTieWithTheSmallerEventID() {
    let events = [timed("b", from: 5, to: 10), timed("a", from: 5, to: 20)]

    let upcoming = EventMatcher.upcomingEvents(from: at(0), window: 60 * 60, among: events)

    #expect(upcoming.map(\.id) == ["google:a", "google:b"])
}
