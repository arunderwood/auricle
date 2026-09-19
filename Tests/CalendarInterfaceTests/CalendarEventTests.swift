import CalendarInterface
import Foundation
import Testing

private func makeEvent(attendees: [CalendarAttendee]) -> CalendarEvent {
    CalendarEvent(
        id: CalendarEventID.google(eventID: "evt1")!,
        title: "Planning",
        attendees: attendees,
        start: Date(timeIntervalSince1970: 1000),
        end: Date(timeIntervalSince1970: 2000),
    )
}

@Test func attendeeDisplayNamesReturnsOnlyTheNamesAndSkipsUnnamedAttendees() {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "alice@example.com", displayName: "Alice"),
        CalendarAttendee(email: "bob.smith@example.org"),
        CalendarAttendee(email: "carol@example.net", displayName: "Carol Jones"),
    ])

    #expect(event.attendeeDisplayNames == ["Alice", "Carol Jones"])
}

@Test func attendeeDisplayNamesIsEmptyWhenNoAttendeeHasAName() {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "alice@example.com"),
        CalendarAttendee(email: "bob@example.org"),
    ])

    #expect(event.attendeeDisplayNames.isEmpty)
}

@Test func attendeeDisplayNamesNeverDerivesANameFromAnEmail() {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "alice.wonder@example.com"),
        CalendarAttendee(email: "bob@example.org", displayName: "Bob"),
    ])

    let joined = event.attendeeDisplayNames.joined(separator: " ")
    #expect(!joined.contains("@"))
    #expect(!joined.lowercased().contains("alice"))
    #expect(!joined.contains("example"))
}

@Test func attendeeDisplayNamesSkipsAnEmptyOrBlankName() {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "a@example.com", displayName: ""),
        CalendarAttendee(email: "b@example.com", displayName: "   "),
        CalendarAttendee(email: "c@example.com", displayName: "Carol"),
    ])

    #expect(event.attendeeDisplayNames == ["Carol"])
}

@Test func attendeeDisplayNamesSkipsANameThatIsShapedLikeAnEmail() {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "alice@example.com", displayName: "alice.wonder@example.org"),
        CalendarAttendee(email: "bob@example.com", displayName: "Bob <bob@example.com>"),
        CalendarAttendee(email: "carol@example.com", displayName: "Carol"),
    ])

    #expect(event.attendeeDisplayNames == ["Carol"])
}

@Test func attendeeDisplayNamesReturnsAPaddedNameTrimmed() {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "alice@example.com", displayName: "  Alice Smith \n"),
    ])

    #expect(event.attendeeDisplayNames == ["Alice Smith"])
}

@Test func attendeeDisplayNamesSkipsANameEqualToTheAttendeesOwnEmail() {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "alice", displayName: " ALICE "),
        CalendarAttendee(email: "bob@example.com", displayName: "bob@example.com"),
        CalendarAttendee(email: "carol@example.com", displayName: "Carol"),
    ])

    #expect(event.attendeeDisplayNames == ["Carol"])
}

@Test func attendeesKeepEveryoneEvenWhenTheyHaveNoName() {
    let event = makeEvent(attendees: [
        CalendarAttendee(email: "alice@example.com", displayName: "Alice"),
        CalendarAttendee(email: "bob@example.org"),
    ])

    #expect(event.attendees.count == 2)
    #expect(event.attendees[1].displayName == nil)
}

@Test func googleEventIDCarriesTheGoogleNamespace() throws {
    let id = try #require(CalendarEventID.google(eventID: "abc123"))

    #expect(id.rawValue == "google:abc123")
    #expect(id.description == "google:abc123")
    #expect(id.namespace == "google")
    #expect(id.eventID == "abc123")
}

@Test func calendarEventIDParsesANamespacedString() throws {
    let id = try #require(CalendarEventID(namespacedID: "google:abc123"))

    #expect(id == CalendarEventID.google(eventID: "abc123"))
}

@Test func calendarEventIDKeepsAColonInsideTheEventPart() throws {
    let id = try #require(CalendarEventID(namespace: "google", eventID: "a:b"))

    #expect(id.rawValue == "google:a:b")
    #expect(id.namespace == "google")
    #expect(id.eventID == "a:b")
    #expect(CalendarEventID(namespacedID: "google:a:b") == id)
}

@Test func calendarEventIDRejectsAMalformedNamespacedString() {
    #expect(CalendarEventID(namespacedID: "abc123") == nil)
    #expect(CalendarEventID(namespacedID: ":abc123") == nil)
    #expect(CalendarEventID(namespacedID: "google:") == nil)
    #expect(CalendarEventID(namespacedID: "") == nil)
    #expect(CalendarEventID(namespace: "", eventID: "abc") == nil)
    #expect(CalendarEventID(namespace: "a:b", eventID: "abc") == nil)
    #expect(CalendarEventID.google(eventID: "") == nil)
}

@Test func calendarEventIDsWithDifferentNamespacesAreDistinct() throws {
    let google = try #require(CalendarEventID(namespace: "google", eventID: "1"))
    let other = try #require(CalendarEventID(namespace: "outlook", eventID: "1"))

    #expect(google != other)
}

@Test func calendarErrorCasesAreEquatable() {
    #expect(CalendarError.notAuthorized == CalendarError.notAuthorized)
    #expect(CalendarError.authorizationFailed(reason: "a") == CalendarError.authorizationFailed(reason: "a"))
    #expect(CalendarError.authorizationFailed(reason: "a") != CalendarError.authorizationFailed(reason: "b"))
    #expect(CalendarError.unreachable != CalendarError.rateLimited)
}
