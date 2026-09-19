import CalendarInterface
import Foundation
@testable import GoogleCalendarSource
import Testing

/// A generous ceiling for "returned promptly": far below the 10-second
/// per-request timeout, so a lookup that waited on the request rather than on
/// the lookup bound would fail it.
private let promptly = Duration.seconds(5)

private let lookupTimeout = Duration.milliseconds(50)

private func elapsedTime(of work: () async -> Void) async -> Duration {
    let start = ContinuousClock.now
    await work()
    return ContinuousClock.now - start
}

// MARK: - The bound

@Test func aLookupWhoseEventsRequestNeverAnswersEndsAsUnreachableWithinTheBound() async throws {
    let harness = try SourceHarness(lookupTimeout: lookupTimeout, events: { _, _ in .hang })
    defer { harness.cleanup() }

    let elapsed = await elapsedTime {
        await #expect(throws: CalendarError.unreachable) {
            try await harness.source.fetchActiveEvent(at: testInstant)
        }
    }

    #expect(elapsed < promptly)
    #expect(harness.stub.eventRequests.count == 1)
}

@Test func anUpcomingEventsLookupIsBoundedToo() async throws {
    let harness = try SourceHarness(lookupTimeout: lookupTimeout, events: { _, _ in .hang })
    defer { harness.cleanup() }

    let elapsed = await elapsedTime {
        await #expect(throws: CalendarError.unreachable) {
            try await harness.source.upcomingEvents(in: 3600)
        }
    }

    #expect(elapsed < promptly)
}

@Test func theBoundCoversTheTokenRefresh() async throws {
    let harness = try SourceHarness(lookupTimeout: lookupTimeout, token: { _, _ in .hang })
    defer { harness.cleanup() }

    let elapsed = await elapsedTime {
        await #expect(throws: CalendarError.unreachable) {
            try await harness.source.fetchActiveEvent(at: testInstant)
        }
    }

    #expect(elapsed < promptly)
    #expect(harness.stub.eventRequests.isEmpty)
}

@Test func theBoundCoversTheRetryAfterARejectedAccessToken() async throws {
    let harness = try SourceHarness(
        lookupTimeout: .milliseconds(500),
        events: { _, index in index == 0 ? .json(401, ["error": ["code": 401]]) : .hang },
    )
    defer { harness.cleanup() }

    let elapsed = await elapsedTime {
        await #expect(throws: CalendarError.unreachable) {
            try await harness.source.fetchActiveEvent(at: testInstant)
        }
    }

    #expect(elapsed < promptly)
    #expect(harness.stub.tokenRequests.count == 2)
    #expect(harness.stub.eventRequests.count == 2)
}

@Test func aLookupThatAnswersInsideTheBoundIsUnaffectedByIt() async throws {
    let harness = try SourceHarness(
        lookupTimeout: .seconds(30),
        events: { _, _ in eventList([eventJSON(id: "evt", start: at(minutes: -5), end: at(minutes: 5))]) },
    )
    defer { harness.cleanup() }

    #expect(try await harness.source.fetchActiveEvent(at: testInstant)?.id == "google:evt")
}

@Test func theActorStaysFreeWhileALookupWaits() async throws {
    let harness = try SourceHarness(
        lookupTimeout: .milliseconds(600),
        events: { _, index in index == 0 ? .hang : eventList([eventJSON(id: "evt", start: at(minutes: -5), end: at(minutes: 5))]) },
    )
    defer { harness.cleanup() }
    let source = harness.source
    let order = Recorder<String>()

    let hung = Task {
        _ = try? await source.fetchActiveEvent(at: testInstant)
        order.record("hung lookup ended")
    }
    try await waitUntil { harness.stub.eventRequests.count == 1 }

    let event = try await source.fetchActiveEvent(at: testInstant)
    order.record("second lookup returned")
    await hung.value

    #expect(event?.id == "google:evt")
    #expect(order.values == ["second lookup returned", "hung lookup ended"])
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

@Test func cancellingTheCallingTaskDuringALookupEndsAsCancellationNotUnreachable() async throws {
    let harness = try SourceHarness(events: { _, _ in .hang })
    defer { harness.cleanup() }
    let source = harness.source

    let lookup = Task { try await source.fetchActiveEvent(at: testInstant) }
    try await waitUntil { harness.stub.eventRequests.count == 1 }
    lookup.cancel()

    var outcome: Result<CalendarEvent?, any Error>?
    let elapsed = await elapsedTime { outcome = await lookup.result }

    #expect(elapsed < promptly)
    switch try #require(outcome) {
    case .success:
        Issue.record("a cancelled lookup must not return an event")
    case let .failure(error):
        #expect(!(error is CalendarError), "cancellation must not be reported as a CalendarError")
        #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
}

@Test func cancellingTheCallingTaskDuringATokenRefreshEndsAsCancellation() async throws {
    let harness = try SourceHarness(token: { _, _ in .hang })
    defer { harness.cleanup() }
    let source = harness.source

    let lookup = Task { try await source.upcomingEvents(in: 3600) }
    try await waitUntil { harness.stub.tokenRequests.count == 1 }
    lookup.cancel()

    var outcome: Result<[CalendarEvent], any Error>?
    let elapsed = await elapsedTime { outcome = await lookup.result }

    #expect(elapsed < promptly)
    switch try #require(outcome) {
    case .success:
        Issue.record("a cancelled lookup must not return events")
    case let .failure(error):
        #expect(!(error is CalendarError), "cancellation must not be reported as a CalendarError")
        #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
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
