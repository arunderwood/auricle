import CalendarInterface
import Foundation
@testable import GoogleCalendarSource
import Testing

// Each internal `GoogleCalendarFailure` case, provoked through the source, must
// come out of the public methods as the `CalendarError` it maps to.

private struct LookupScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let storedRefreshToken: String?
    let token: StubReply
    let events: StubReply
    let internalFailure: GoogleCalendarFailure
    let publicError: CalendarError

    var testDescription: String {
        name
    }
}

private let freshToken = StubReply.json(200, ["access_token": "access-1", "expires_in": 3600])

private let lookupScenarios: [LookupScenario] = [
    LookupScenario(
        name: "notAuthorized",
        storedRefreshToken: nil,
        token: freshToken,
        events: .json(200, ["items": [Any]()]),
        internalFailure: .notAuthorized,
        publicError: .authorizationExpired,
    ),
    LookupScenario(
        name: "authorizationExpired",
        storedRefreshToken: "1//stored",
        token: .json(400, ["error": "invalid_grant"]),
        events: .json(200, ["items": [Any]()]),
        internalFailure: .authorizationExpired,
        publicError: .authorizationExpired,
    ),
    LookupScenario(
        name: "authorizationFailed",
        storedRefreshToken: "1//stored",
        token: .json(401, ["error": "invalid_client"]),
        events: .json(200, ["items": [Any]()]),
        internalFailure: .authorizationFailed(reason: "Google rejected the token request"),
        publicError: .authorizationExpired,
    ),
    LookupScenario(
        name: "unreachable",
        storedRefreshToken: "1//stored",
        token: freshToken,
        events: .text(503, "unavailable"),
        internalFailure: .unreachable,
        publicError: .unreachable,
    ),
    LookupScenario(
        name: "rateLimited",
        storedRefreshToken: "1//stored",
        token: freshToken,
        events: .text(429, "slow down"),
        internalFailure: .rateLimited,
        publicError: .unreachable,
    ),
    LookupScenario(
        name: "malformedResponse",
        storedRefreshToken: "1//stored",
        token: freshToken,
        events: .text(200, "not json"),
        internalFailure: .malformedResponse,
        publicError: .unreachable,
    ),
]

private func harness(for scenario: LookupScenario) throws -> SourceHarness {
    try SourceHarness(
        storedRefreshToken: scenario.storedRefreshToken,
        token: { _, _ in scenario.token },
        events: { _, _ in scenario.events },
    )
}

@Test(arguments: lookupScenarios)
private func fetchActiveEventReportsTheMappedCalendarError(scenario: LookupScenario) async throws {
    let harness = try harness(for: scenario)
    defer { harness.cleanup() }

    await #expect(throws: scenario.publicError) {
        try await harness.source.fetchActiveEvent(at: testInstant)
    }
}

@Test(arguments: lookupScenarios)
private func upcomingEventsReportsTheMappedCalendarError(scenario: LookupScenario) async throws {
    let harness = try harness(for: scenario)
    defer { harness.cleanup() }

    await #expect(throws: scenario.publicError) {
        try await harness.source.upcomingEvents(in: 3600)
    }
}

@Test(arguments: lookupScenarios)
private func theListCallKeepsTheFinerInternalFailure(scenario: LookupScenario) async throws {
    let harness = try harness(for: scenario)
    defer { harness.cleanup() }

    await #expect(throws: scenario.internalFailure) {
        try await harness.source.listEvents(timeMin: testInstant, timeMax: testInstant.addingTimeInterval(1))
    }
}

private struct StatusScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let reply: StubReply
    let failure: GoogleCalendarFailure

    var testDescription: String {
        name
    }
}

private let statusScenarios: [StatusScenario] = [
    StatusScenario(name: "429", reply: .text(429, "slow down"), failure: .rateLimited),
    StatusScenario(name: "403 with a rate limit reason", reply: .json(403, ["error": ["errors": [["reason": "rateLimitExceeded"]]]]), failure: .rateLimited),
    StatusScenario(name: "403 with another reason", reply: .json(403, ["error": ["errors": [["reason": "insufficientPermissions"]]]]), failure: .authorizationExpired),
    StatusScenario(name: "403 with an unreadable body", reply: .text(403, "<html>Forbidden</html>"), failure: .authorizationExpired),
    StatusScenario(name: "500", reply: .text(500, "oops"), failure: .unreachable),
    StatusScenario(name: "503", reply: .text(503, "unavailable"), failure: .unreachable),
    StatusScenario(name: "404", reply: .text(404, "not found"), failure: .malformedResponse),
    StatusScenario(name: "undecodable 200", reply: .text(200, "not json"), failure: .malformedResponse),
    StatusScenario(
        name: "unparseable dateTime",
        reply: .json(200, ["items": [["id": "bad", "start": ["dateTime": "soon"], "end": ["dateTime": "later"]]]]),
        failure: .malformedResponse,
    ),
    StatusScenario(name: "401 twice", reply: .json(401, ["error": ["code": 401]]), failure: .authorizationExpired),
]

@Test(arguments: statusScenarios)
private func theCalendarAPIResponseIsClassifiedByTheInternalFailure(scenario: StatusScenario) async throws {
    let harness = try SourceHarness(events: { _, _ in scenario.reply })
    defer { harness.cleanup() }

    await #expect(throws: scenario.failure) {
        try await harness.source.listEvents(timeMin: testInstant, timeMax: testInstant.addingTimeInterval(1))
    }
}

@Test func aConnectionFailureToTheCalendarAPIIsUnreachableInternally() async throws {
    let harness = try SourceHarness(events: { _, _ in .failure(URLError(.notConnectedToInternet)) })
    defer { harness.cleanup() }

    await #expect(throws: GoogleCalendarFailure.unreachable) {
        try await harness.source.listEvents(timeMin: testInstant, timeMax: testInstant.addingTimeInterval(1))
    }
}

// MARK: - authorize()

private struct AuthorizeScenario: Sendable, CustomTestStringConvertible {
    let name: String
    let token: StubReply
    let redirectError: String?
    let publicError: CalendarError

    var testDescription: String {
        name
    }
}

private let authorizeScenarios: [AuthorizeScenario] = [
    AuthorizeScenario(name: "consent denied", token: freshToken, redirectError: "access_denied", publicError: .authorizationExpired),
    AuthorizeScenario(name: "code rejected", token: .json(400, ["error": "invalid_grant"]), redirectError: nil, publicError: .authorizationExpired),
    AuthorizeScenario(name: "token endpoint unreachable", token: .text(503, "unavailable"), redirectError: nil, publicError: .unreachable),
    AuthorizeScenario(name: "token endpoint throttled", token: .text(429, "slow down"), redirectError: nil, publicError: .unreachable),
    AuthorizeScenario(name: "token response undecodable", token: .text(200, "not json"), redirectError: nil, publicError: .unreachable),
]

@Test(arguments: authorizeScenarios)
private func authorizeReportsTheMappedCalendarError(scenario: AuthorizeScenario) async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in
            try await deliverRedirect(for: url, code: scenario.redirectError == nil ? "auth-code" : nil, error: scenario.redirectError)
        },
        token: { _, _ in scenario.token },
    )
    defer { harness.cleanup() }

    await #expect(throws: scenario.publicError) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
}
