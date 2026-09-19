import CalendarInterface
import Foundation
@testable import GoogleCalendarSource
import Testing

// Nothing here measures elapsed time. A request timeout far longer than any
// test run means only the lookup bound can end a request that never answers,
// so a bound that failed to fire ends the test through its `.timeLimit`
// instead of passing on luck. Assertions are on results and on request
// counts that hold however the bound's timer and the request are scheduled.

/// Long enough that no request in these tests can time out on its own.
private let neverTimesOut: TimeInterval = 600

/// Small enough that the bound is what ends a request that never answers.
private let smallBound = Duration.milliseconds(20)

private func isCancellation(_ error: any Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

// MARK: - The bound

@Test(.timeLimit(.minutes(1)))
func aLookupWhoseEventsRequestNeverAnswersEndsAsUnreachable() async throws {
    let harness = try SourceHarness(lookupTimeout: smallBound, requestTimeout: neverTimesOut, events: { _, _ in .hang })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }

    #expect(harness.stub.tokenRequests.count <= 1)
    #expect(harness.stub.eventRequests.count <= 1)
}

@Test(.timeLimit(.minutes(1)))
func anUpcomingEventsLookupIsBoundedToo() async throws {
    let harness = try SourceHarness(lookupTimeout: smallBound, requestTimeout: neverTimesOut, events: { _, _ in .hang })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.upcomingEvents(in: 3600)
    }

    #expect(harness.stub.eventRequests.count <= 1)
}

@Test(.timeLimit(.minutes(1)))
func theBoundCoversTheTokenRefresh() async throws {
    let harness = try SourceHarness(lookupTimeout: smallBound, requestTimeout: neverTimesOut, token: { _, _ in .hang })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }

    #expect(harness.stub.tokenRequests.count <= 1)
    #expect(harness.stub.eventRequests.isEmpty)
}

@Test(.timeLimit(.minutes(1)))
func aLookupThatAnswersReturnsWithoutWaitingOutTheBound() async throws {
    let harness = try SourceHarness(
        lookupTimeout: .seconds(3600),
        events: { _, _ in eventList([eventJSON(id: "evt", start: at(minutes: -5), end: at(minutes: 5))]) },
    )
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:evt")
    #expect(try await harness.source.upcomingEvents(in: 3600).isEmpty)
}

@Test(.timeLimit(.minutes(2)))
func theActorStaysFreeWhileALookupWaits() async throws {
    let harness = try SourceHarness(
        lookupTimeout: .seconds(60),
        requestTimeout: neverTimesOut,
        events: { _, index in index == 0 ? .hang : eventList([eventJSON(id: "evt", start: at(minutes: -5), end: at(minutes: 5))]) },
    )
    defer { harness.cleanup() }
    let source = harness.source
    let order = Recorder<String>()

    let hung = Task {
        do {
            _ = try await source.fetchActiveEvent(at: testInstant)
            order.record("hung lookup returned")
        } catch where isCancellation(error) {
            order.record("hung lookup cancelled")
        } catch {
            order.record("hung lookup failed")
        }
    }
    try await waitUntil { harness.stub.eventRequests.count == 1 }

    let event = try await source.fetchActiveEvent(at: testInstant)
    order.record("second lookup returned")

    hung.cancel()
    await hung.value

    #expect(event?.id == "google:evt")
    #expect(order.values == ["second lookup returned", "hung lookup cancelled"])
}

@Test func authorizeIsNotBoundedByTheLookupTimeout() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        lookupTimeout: .milliseconds(1),
        openBrowser: { url in
            try await Task.sleep(for: .milliseconds(100))
            try await deliverRedirect(for: url)
        },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()

    #expect(harness.storedRefreshToken == "1//new-refresh-token")
}

// MARK: - Cancellation

@Test(.timeLimit(.minutes(2)))
func cancellingTheCallingTaskDuringALookupEndsAsCancellationNotUnreachable() async throws {
    let harness = try SourceHarness(requestTimeout: neverTimesOut, events: { _, _ in .hang })
    defer { harness.cleanup() }
    let source = harness.source

    let lookup = Task { try await source.fetchActiveEvent(at: testInstant) }
    try await waitUntil { harness.stub.eventRequests.count == 1 }
    lookup.cancel()

    switch await lookup.result {
    case .success:
        Issue.record("a cancelled lookup must not return an event")
    case let .failure(error):
        #expect(!(error is CalendarError), "cancellation must not be reported as a CalendarError")
        #expect(isCancellation(error))
    }
}

@Test(.timeLimit(.minutes(2)))
func cancellingTheCallingTaskDuringATokenRefreshEndsAsCancellation() async throws {
    let harness = try SourceHarness(requestTimeout: neverTimesOut, token: { _, _ in .hang })
    defer { harness.cleanup() }
    let source = harness.source

    let lookup = Task { try await source.upcomingEvents(in: 3600) }
    try await waitUntil { harness.stub.tokenRequests.count == 1 }
    lookup.cancel()

    switch await lookup.result {
    case .success:
        Issue.record("a cancelled lookup must not return events")
    case let .failure(error):
        #expect(!(error is CalendarError), "cancellation must not be reported as a CalendarError")
        #expect(isCancellation(error))
    }
}

// MARK: - Per-request timeout

@Test func everyOutgoingRequestCarriesATenSecondTimeout() async throws {
    let harness = try SourceHarness()
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.map(\.timeoutInterval) == [10])
    #expect(harness.stub.eventRequests.map(\.timeoutInterval) == [10])
}

@Test func anOverriddenRequestTimeoutReachesTheTokenAndTheEventsRequests() async throws {
    let harness = try SourceHarness(requestTimeout: neverTimesOut)
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.map(\.timeoutInterval) == [neverTimesOut])
    #expect(harness.stub.eventRequests.map(\.timeoutInterval) == [neverTimesOut])
}
