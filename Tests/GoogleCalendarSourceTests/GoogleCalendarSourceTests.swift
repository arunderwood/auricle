import CalendarInterface
import Foundation
@testable import GoogleCalendarSource
import Testing

private func rateLimitBody(reason: String) -> [String: Any] {
    ["error": ["code": 403, "message": "quota", "errors": [["domain": "usageLimits", "reason": reason]]]]
}

// MARK: - Active event

@Test func fetchActiveEventReturnsTheEventCoveringTheInstant() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(
                id: "evt1",
                summary: "Roadmap sync",
                start: at(minutes: -10),
                end: at(minutes: 20),
                attendees: [["email": "alice@example.com", "displayName": "Alice"], ["email": "bob@example.org"]],
            ),
        ])
    })
    defer { harness.cleanup() }

    let event = try #require(await harness.source.fetchActiveEvent(at: testInstant))

    #expect(event.id == "google:evt1")
    #expect(event.title == "Roadmap sync")
    #expect(event.start == at(minutes: -10))
    #expect(event.end == at(minutes: 20))
    #expect(event.attendees == [
        CalendarAttendee(email: "alice@example.com", displayName: "Alice", isSelf: false),
        CalendarAttendee(email: "bob@example.org", displayName: nil, isSelf: false),
    ])
}

@Test func fetchActiveEventSendsAnHTTPSBearerRequestForThePrimaryCalendar() async throws {
    let harness = try SourceHarness(events: { _, _ in eventList([]) })
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    let request = try #require(harness.stub.eventRequests.first)
    #expect(harness.stub.eventRequests.count == 1)
    #expect(request.method == "GET")
    #expect(request.url.scheme == "https")
    #expect(request.url.path.hasSuffix("/calendar/v3/calendars/primary/events"))
    #expect(request.bearerToken == "access-1")

    let query = request.query
    #expect(query["singleEvents"] == "true")
    #expect(query["timeMin"] == iso8601(testInstant.addingTimeInterval(-1)))
    #expect(query["timeMax"] == iso8601(testInstant.addingTimeInterval(1)))
    #expect(query["fields"] == "items(id,status,summary,start(dateTime),end(dateTime),attendees(email,displayName,self))")
}

@Test func fetchActiveEventAsksForTheInstantItIsGivenNotTheCurrentTime() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([eventJSON(id: "evt", start: at(minutes: -5), end: at(minutes: 5))])
    })
    defer { harness.cleanup() }
    harness.clock.advance(by: 86400)

    let event = try await harness.source.fetchActiveEvent(at: testInstant)

    let query = try #require(harness.stub.eventRequests.first).query
    #expect(query["timeMin"] == iso8601(testInstant.addingTimeInterval(-1)))
    #expect(query["timeMax"] == iso8601(testInstant.addingTimeInterval(1)))
    #expect(event?.id == "google:evt")
}

@Test func fetchActiveEventRefreshesUsingTheStoredTokenAndTheClientCredentials() async throws {
    let harness = try SourceHarness(
        client: GoogleOAuthClient(clientID: "client-x", clientSecret: "secret-y"),
        storedRefreshToken: "1//stored",
    )
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    let refresh = try #require(harness.stub.tokenRequests.first)
    #expect(refresh.method == "POST")
    #expect(refresh.url.scheme == "https")
    #expect(refresh.form["grant_type"] == "refresh_token")
    #expect(refresh.form["refresh_token"] == "1//stored")
    #expect(refresh.form["client_id"] == "client-x")
    #expect(refresh.form["client_secret"] == "secret-y")
}

@Test func fetchActiveEventOmitsTheClientSecretWhenTheClientHasNone() async throws {
    let harness = try SourceHarness()
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.first?.form["client_secret"] == nil)
}

@Test func fetchActiveEventPicksTheShortestOfSeveralOverlappingEvents() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "all-hands", start: at(minutes: -60), end: at(minutes: 60)),
            eventJSON(id: "breakout", start: at(minutes: -5), end: at(minutes: 25)),
            eventJSON(id: "quick", start: at(minutes: -1), end: at(minutes: 9)),
        ])
    })
    defer { harness.cleanup() }

    let event = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(event?.id == "google:quick")
}

@Test func fetchActiveEventPrefersTheLaterStartWhenOneEventEndsExactlyWhenAnotherStarts() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "first", start: at(minutes: -30), end: testInstant),
            eventJSON(id: "second", start: testInstant, end: at(minutes: 30)),
        ])
    })
    defer { harness.cleanup() }

    let event = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(event?.id == "google:second")
}

@Test func fetchActiveEventMatchesAnEventThatEndsExactlyAtTheInstant() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([eventJSON(id: "ending", start: at(minutes: -30), end: testInstant)])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:ending")
}

@Test func fetchActiveEventReturnsNilWhenNothingCoversTheInstant() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([eventJSON(id: "later", start: at(minutes: 30), end: at(minutes: 60))])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant) == nil)
}

@Test func fetchActiveEventReturnsNilWhenTheCalendarIsEmpty() async throws {
    let harness = try SourceHarness(events: { _, _ in .json(200, [String: Any]()) })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant) == nil)
}

@Test func fetchActiveEventIgnoresAllDayAndCancelledEvents() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "holiday", start: nil, end: nil, allDayDate: "2027-01-15"),
            eventJSON(id: "gone", start: at(minutes: -5), end: at(minutes: 5), status: "cancelled"),
        ])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant) == nil)
}

@Test func anAllDayEventWithoutADateTimeIsSkippedWhateverShapeGoogleGivesItsTimes() async throws {
    let harness = try SourceHarness(events: { _, _ in
        let emptyTimes: [String: Any] = ["id": "empty-times", "status": "confirmed", "summary": "All day", "start": [String: Any](), "end": [String: Any]()]
        let missingTimes: [String: Any] = ["id": "missing-times", "status": "confirmed", "summary": "All day"]
        return eventList([emptyTimes, missingTimes])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant) == nil)
    #expect(try await harness.source.upcomingEvents(in: 3600).isEmpty)
}

@Test func fetchActiveEventAcceptsUTCOffsetsAndFractionalSecondsInEventTimes() async throws {
    let harness = try SourceHarness(events: { _, _ in
        // 1_800_000_000 is 2027-01-15T08:00:00Z.
        let offsetEvent: [String: Any] = [
            "id": "offset",
            "status": "confirmed",
            "summary": "Offset times",
            "start": ["dateTime": "2027-01-14T23:59:59.500-08:00"],
            "end": ["dateTime": "2027-01-15T09:00:00+01:00"],
        ]
        return eventList([offsetEvent])
    })
    defer { harness.cleanup() }

    let event = try #require(await harness.source.fetchActiveEvent(at: testInstant))

    #expect(event.start == Date(timeIntervalSince1970: 1_800_000_000 - 0.5))
    #expect(event.end == Date(timeIntervalSince1970: 1_800_000_000))
}

@Test func fetchActiveEventUsesAnEmptyTitleWhenTheEventHasNone() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([eventJSON(id: "untitled", summary: nil, start: at(minutes: -5), end: at(minutes: 5))])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.title == "")
}

// MARK: - Event mapping

@Test func everyEventIdCarriesTheGoogleNamespacePrefix() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "abc123", start: at(minutes: -5), end: at(minutes: 5)),
            eventJSON(id: "next:one", start: at(minutes: 10), end: at(minutes: 20)),
        ])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:abc123")
    #expect(try await harness.source.upcomingEvents(in: 3600).map(\.id) == ["google:next:one"])
}

@Test func anEventWithAnEmptyIdIsNeverReturned() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([eventJSON(id: "", start: at(minutes: -5), end: at(minutes: 5))])
    })
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant) == nil)
}

@Test func anAttendeeIsSelfOnlyWhenGoogleSaysSo() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(
                id: "evt",
                start: at(minutes: -5),
                end: at(minutes: 5),
                attendees: [
                    ["email": "me@example.com", "displayName": "Me", "self": true],
                    ["email": "other@example.com", "displayName": "Other", "self": false],
                    ["email": "absent@example.com", "displayName": "Absent"],
                ],
            ),
        ])
    })
    defer { harness.cleanup() }

    let event = try #require(await harness.source.fetchActiveEvent(at: testInstant))

    #expect(event.attendees.map(\.isSelf) == [true, false, false])
    #expect(event.attendees.map(\.email) == ["me@example.com", "other@example.com", "absent@example.com"])
}

@Test func anAttendeeWithoutAnEmailKeepsAnEmptyEmailAndItsName() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "evt", start: at(minutes: -5), end: at(minutes: 5), attendees: [["displayName": "Conference Room", "self": true]]),
        ])
    })
    defer { harness.cleanup() }

    let event = try #require(await harness.source.fetchActiveEvent(at: testInstant))

    #expect(event.attendees == [CalendarAttendee(email: "", displayName: "Conference Room", isSelf: true)])
}

@Test func displayNamesPassThroughExactlyAsGoogleSentThem() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(
                id: "evt",
                start: at(minutes: -5),
                end: at(minutes: 5),
                attendees: [
                    ["email": "a@example.com", "displayName": "  Padded Name "],
                    ["email": "b@example.com", "displayName": "b@example.com"],
                ],
            ),
        ])
    })
    defer { harness.cleanup() }

    let event = try #require(await harness.source.fetchActiveEvent(at: testInstant))

    #expect(event.attendees.map(\.displayName) == ["  Padded Name ", "b@example.com"])
}

// MARK: - Access token lifecycle

@Test func anAccessTokenIsReusedUntilItIsCloseToExpiry() async throws {
    let harness = try SourceHarness()
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)
    harness.clock.advance(by: 3000)
    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.count == 1)
    #expect(harness.stub.eventRequests.map(\.bearerToken) == ["access-1", "access-1"])
}

@Test func anExpiredAccessTokenIsRefreshedBeforeTheCall() async throws {
    let harness = try SourceHarness()
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)
    harness.clock.advance(by: 3601)
    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.count == 2)
    #expect(harness.stub.eventRequests.map(\.bearerToken) == ["access-1", "access-2"])
}

@Test func anAccessTokenWithinSixtySecondsOfExpiryIsRefreshedBeforeTheCall() async throws {
    let harness = try SourceHarness()
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)
    harness.clock.advance(by: 3600 - 30)
    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.count == 2)
    #expect(harness.stub.eventRequests.last?.bearerToken == "access-2")
}

@Test func aRejectedAccessTokenIsRefreshedOnceAndTheCallRetriedOnce() async throws {
    let harness = try SourceHarness(events: { _, index in
        index == 0 ? .json(401, ["error": ["code": 401]]) : eventList([eventJSON(id: "evt", start: at(minutes: -5), end: at(minutes: 5))])
    })
    defer { harness.cleanup() }

    let event = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(event?.id == "google:evt")
    #expect(harness.stub.tokenRequests.count == 2)
    #expect(harness.stub.eventRequests.map(\.bearerToken) == ["access-1", "access-2"])
}

@Test func aSecondRejectionMeansAuthorizationExpiredWithNoFurtherRetry() async throws {
    let harness = try SourceHarness(events: { _, _ in .json(401, ["error": ["code": 401]]) })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    #expect(harness.stub.eventRequests.count == 2)
    #expect(harness.stub.tokenRequests.count == 2)
}

@Test func aRevokedRefreshTokenMeansAuthorizationExpiredAndTheKeychainItemStays() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: "1//revoked",
        token: { _, _ in .json(400, ["error": "invalid_grant", "error_description": "Token has been expired or revoked."]) },
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    #expect(harness.stub.eventRequests.isEmpty)
    #expect(harness.storedRefreshToken == "1//revoked")
}

@Test func aRefreshRejectedForAnotherReasonIsReportedAsAnExpiredAuthorization() async throws {
    let harness = try SourceHarness(token: { _, _ in .json(401, ["error": "invalid_client"]) })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
}

@Test func aNeverAuthorizedSourceFailsWithoutAnyNetworkCall() async throws {
    let harness = try SourceHarness(storedRefreshToken: nil)
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.upcomingEvents(in: 3600)
    }
    #expect(harness.stub.requests.isEmpty)
}

// MARK: - Failure mapping

@Test func aTransportFailureIsUnreachable() async throws {
    let harness = try SourceHarness(events: { _, _ in .failure(URLError(.notConnectedToInternet)) })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    #expect(harness.stub.eventRequests.count == 1)
}

@Test func aFailureReachingTheTokenEndpointIsUnreachable() async throws {
    let harness = try SourceHarness(token: { _, _ in .failure(URLError(.timedOut)) })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    #expect(harness.stub.eventRequests.isEmpty)
}

@Test func aServerErrorIsUnreachableWithNoRetry() async throws {
    let harness = try SourceHarness(events: { _, _ in .text(503, "unavailable") })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    #expect(harness.stub.eventRequests.count == 1)
}

@Test func aTooManyRequestsResponseIsUnreachableWithNoRetry() async throws {
    let harness = try SourceHarness(events: { _, _ in .text(429, "slow down") })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    #expect(harness.stub.eventRequests.count == 1)
}

@Test func aTokenEndpointThrottleIsUnreachable() async throws {
    let harness = try SourceHarness(token: { _, _ in .text(429, "slow down") })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
}

@Test(arguments: ["rateLimitExceeded", "userRateLimitExceeded", "dailyLimitExceeded", "quotaExceeded", "calendarUsageLimitsExceeded"])
func aForbiddenResponseWithARateLimitReasonIsUnreachable(reason: String) async throws {
    let harness = try SourceHarness(events: { _, _ in .json(403, rateLimitBody(reason: reason)) })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    #expect(harness.stub.eventRequests.count == 1)
}

@Test func aForbiddenResponseWithAnyOtherReasonMeansAuthorizationExpired() async throws {
    let harness = try SourceHarness(events: { _, _ in .json(403, rateLimitBody(reason: "insufficientPermissions")) })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
    #expect(harness.stub.eventRequests.count == 1)
}

@Test func aForbiddenResponseWithAnUnreadableBodyMeansAuthorizationExpired() async throws {
    let harness = try SourceHarness(events: { _, _ in .text(403, "<html>Forbidden</html>") })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
}

@Test func anUndecodableSuccessBodyIsUnreachable() async throws {
    let harness = try SourceHarness(events: { _, _ in .text(200, "not json at all") })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
}

@Test func anEventWithAnUnparseableDateTimeMakesTheLookupUnreachable() async throws {
    let harness = try SourceHarness(events: { _, _ in
        let badEvent: [String: Any] = [
            "id": "bad",
            "start": ["dateTime": "next tuesday"],
            "end": ["dateTime": "next wednesday"],
        ]
        return eventList([badEvent])
    })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
}

@Test func anUnmodelledClientErrorStatusIsUnreachable() async throws {
    let harness = try SourceHarness(events: { _, _ in .text(404, "not found") })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
}

@Test func cancellationPropagatesUntouchedInsteadOfBecomingAnUnreachableError() async throws {
    let harness = try SourceHarness(events: { _, _ in .failure(URLError(.cancelled)) })
    defer { harness.cleanup() }

    await #expect(throws: URLError.self) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
}

// MARK: - Upcoming events

@Test func upcomingEventsReturnsEventsStartingInTheWindowSortedByStartAndExcludesOneAlreadyRunning() async throws {
    let harness = try SourceHarness(events: { _, _ in
        eventList([
            eventJSON(id: "later", start: at(minutes: 50), end: at(minutes: 60)),
            eventJSON(id: "running", start: at(minutes: -10), end: at(minutes: 30)),
            eventJSON(id: "sooner", start: at(minutes: 5), end: at(minutes: 15)),
            eventJSON(id: "outside", start: at(minutes: 61), end: at(minutes: 90)),
            eventJSON(id: "allday", start: nil, end: nil, allDayDate: "2027-01-15"),
            eventJSON(id: "cancelled", start: at(minutes: 10), end: at(minutes: 20), status: "cancelled"),
        ])
    })
    defer { harness.cleanup() }

    let events = try await harness.source.upcomingEvents(in: 60 * 60)

    #expect(events.map(\.id) == ["google:sooner", "google:later"])
}

@Test func upcomingEventsAsksForTheWindowStartingNow() async throws {
    let harness = try SourceHarness()
    defer { harness.cleanup() }

    _ = try await harness.source.upcomingEvents(in: 1800)

    let query = try #require(harness.stub.eventRequests.first).query
    #expect(query["timeMin"] == iso8601(testInstant))
    #expect(query["timeMax"] == iso8601(testInstant.addingTimeInterval(1801)))
    #expect(query["singleEvents"] == "true")
    #expect(query["orderBy"] == "startTime")
}

@Test func upcomingEventsWithANegativeWindowIsEmptyWithoutAnyRequest() async throws {
    let harness = try SourceHarness()
    defer { harness.cleanup() }

    #expect(try await harness.source.upcomingEvents(in: -5).isEmpty)
    #expect(harness.stub.requests.isEmpty)
}
