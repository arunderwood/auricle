import Foundation
@testable import GoogleCalendarSource
import Testing

@Test func fetchActiveEventMatchesAnEventStartingWithinTheLeadInAfterTheInstant() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([eventJSON(id: "about-to-start", start: at(minutes: 3), end: at(minutes: 33))])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:about-to-start")
}

@Test func fetchActiveEventPrefersTheEventAboutToStartOverOneThatIsStillRunning() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "running", start: at(minutes: -59), end: at(minutes: 1)),
            eventJSON(id: "next", start: at(minutes: 1), end: at(minutes: 61)),
        ])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:next")
}

@Test func fetchActiveEventSkipsEventsTheUserDeclined() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(
                id: "declined",
                start: at(minutes: -5),
                end: at(minutes: 5),
                attendees: [
                    ["email": "me@example.com", "self": true, "responseStatus": "declined"],
                    ["email": "other@example.com", "responseStatus": "accepted"],
                ],
            ),
        ])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant) == nil)
}

@Test func fetchActiveEventReadsTheDeclineFromTheSelfAttendeeOnly() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(
                id: "someone-else-declined",
                start: at(minutes: -5),
                end: at(minutes: 5),
                attendees: [
                    ["email": "me@example.com", "self": true, "responseStatus": "accepted"],
                    ["email": "other@example.com", "responseStatus": "declined"],
                ],
            ),
        ])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:someone-else-declined")
}

@Test func fetchActiveEventSkipsFocusTimeOutOfOfficeAndWorkingLocationEvents() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "focus", start: at(minutes: -5), end: at(minutes: 5), eventType: "focusTime"),
            eventJSON(id: "ooo", start: at(minutes: -5), end: at(minutes: 5), eventType: "outOfOffice"),
            eventJSON(id: "where", start: at(minutes: -5), end: at(minutes: 5), eventType: "workingLocation"),
            eventJSON(id: "meeting", start: at(minutes: -30), end: at(minutes: 30), eventType: "default"),
        ])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:meeting")
}

@Test func fetchActiveEventPrefersABusyEventOverAFreeOne() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "free", start: at(minutes: -5), end: at(minutes: 5), transparency: "transparent"),
            eventJSON(id: "busy", start: at(minutes: -30), end: at(minutes: 30)),
        ])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:busy")
}
