import Foundation
@testable import GoogleCalendarSource
import Testing

private func eventsRequest(for stub: GoogleStub, timeoutInterval: TimeInterval = 300) -> URLRequest {
    var request = URLRequest(url: stub.endpoints.calendarAPI.appendingPathComponent("calendars/primary/events"))
    request.timeoutInterval = timeoutInterval
    return request
}

@Test func transportSendsEveryRequestWithATenSecondTimeout() async throws {
    let stub = GoogleStub()
    defer { stub.release() }

    _ = try await GoogleTransport.perform(eventsRequest(for: stub, timeoutInterval: 300), using: stub.session)

    #expect(GoogleTransport.requestTimeout == 10)
    #expect(stub.eventRequests.map(\.timeoutInterval) == [10])
}

@Test func transportReturnsTheStatusAndBodyWithoutInterpretingThem() async throws {
    let stub = GoogleStub(events: { _, _ in .text(503, "unavailable") })
    defer { stub.release() }

    let response = try await GoogleTransport.perform(eventsRequest(for: stub), using: stub.session)

    #expect(response.status == 503)
    #expect(String(bytes: response.body, encoding: .utf8) == "unavailable")
}

@Test func transportReportsAFailedConnectionAsUnreachable() async throws {
    let stub = GoogleStub(events: { _, _ in .failure(URLError(.notConnectedToInternet)) })
    defer { stub.release() }

    await #expect(throws: GoogleCalendarFailure.unreachable) {
        try await GoogleTransport.perform(eventsRequest(for: stub), using: stub.session)
    }
}

@Test func transportReportsATimedOutRequestAsUnreachable() async throws {
    let stub = GoogleStub(events: { _, _ in .failure(URLError(.timedOut)) })
    defer { stub.release() }

    await #expect(throws: GoogleCalendarFailure.unreachable) {
        try await GoogleTransport.perform(eventsRequest(for: stub), using: stub.session)
    }
}

@Test func transportLetsACancelledRequestPropagateAsCancellation() async throws {
    let stub = GoogleStub(events: { _, _ in .failure(URLError(.cancelled)) })
    defer { stub.release() }

    do {
        _ = try await GoogleTransport.perform(eventsRequest(for: stub), using: stub.session)
        Issue.record("a cancelled request must not succeed")
    } catch let error as URLError {
        #expect(error.code == .cancelled)
    } catch {
        Issue.record("expected URLError(.cancelled), got \(type(of: error))")
    }
}
