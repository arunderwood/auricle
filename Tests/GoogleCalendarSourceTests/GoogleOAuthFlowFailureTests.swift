import Foundation
@testable import GoogleCalendarSource
import Testing

// The flow reports the finer `GoogleCalendarFailure`; the source's public
// methods map it to `CalendarError` (GoogleCalendarSourceFailureMappingTests).

// MARK: - authorize(): the browser leg

@Test func theFlowReportsARedirectWithADifferentStateAsAnAuthorizationFailure() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url, state: "forged-state") },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    await #expect(throws: GoogleCalendarFailure.authorizationFailed(reason: "the authorization response did not match this request")) {
        try await harness.flow.authorize()
    }
    #expect(harness.stub.tokenRequests.isEmpty)
}

@Test func theFlowReportsADeniedConsentAsAnAuthorizationFailure() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url, code: nil, error: "access_denied") },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    await #expect(throws: GoogleCalendarFailure.authorizationFailed(reason: "authorization was declined")) {
        try await harness.flow.authorize()
    }
    #expect(harness.stub.tokenRequests.isEmpty)
}

@Test(arguments: ["server_error", "Weird Text With SPACES", "temporarily_unavailable"])
func theFlowGivesAnyOtherOAuthErrorTheSameFixedReason(providerError: String) async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url, code: nil, error: providerError) },
    )
    defer { harness.cleanup() }

    await #expect(throws: GoogleCalendarFailure.authorizationFailed(reason: "authorization was rejected")) {
        try await harness.flow.authorize()
    }
    #expect(harness.stub.tokenRequests.isEmpty)
}

@Test func theFlowReportsAMissingRedirectAsAnAuthorizationFailure() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        redirectTimeout: .milliseconds(200),
        openBrowser: { _ in },
    )
    defer { harness.cleanup() }

    await #expect(throws: GoogleCalendarFailure.authorizationFailed(reason: "no response arrived from the browser before the timeout")) {
        try await harness.flow.authorize()
    }
}

@Test func theFlowReportsABrowserThatCannotBeOpenedAsAnAuthorizationFailure() async throws {
    struct NoBrowser: Error {}
    let harness = try SourceHarness(storedRefreshToken: nil, openBrowser: { _ in throw NoBrowser() })
    defer { harness.cleanup() }

    await #expect(throws: GoogleCalendarFailure.authorizationFailed(reason: "the browser could not be opened")) {
        try await harness.flow.authorize()
    }
}

// MARK: - authorize(): the token exchange

@Test(arguments: [readonlyScope + ".extra", "openid email", ""])
func theFlowReportsAnUngrantedCalendarScopeAsAnAuthorizationFailure(grantedScope: String) async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(scope: grantedScope),
    )
    defer { harness.cleanup() }

    await #expect(throws: GoogleCalendarFailure.authorizationFailed(reason: "Google did not grant read-only calendar access")) {
        try await harness.flow.authorize()
    }
}

@Test func theFlowReportsAMissingRefreshTokenAsAnAuthorizationFailure() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(refreshToken: nil),
    )
    defer { harness.cleanup() }

    await #expect(throws: GoogleCalendarFailure.authorizationFailed(reason: "Google returned no refresh token")) {
        try await harness.flow.authorize()
    }
}

// MARK: - Token endpoint outcomes

private struct TokenOutcome: Sendable, CustomTestStringConvertible {
    let name: String
    let reply: StubReply
    let onAuthorize: GoogleCalendarFailure
    let onRefresh: GoogleCalendarFailure

    var testDescription: String {
        name
    }
}

private let rejectedRequest = GoogleCalendarFailure.authorizationFailed(reason: "Google rejected the token request")

private let tokenOutcomes: [TokenOutcome] = [
    TokenOutcome(
        name: "invalid_grant",
        reply: .json(400, ["error": "invalid_grant", "error_description": "Bad Request"]),
        onAuthorize: .authorizationFailed(reason: "Google rejected the authorization code"),
        onRefresh: .authorizationExpired,
    ),
    TokenOutcome(name: "invalid_client", reply: .json(401, ["error": "invalid_client"]), onAuthorize: rejectedRequest, onRefresh: rejectedRequest),
    TokenOutcome(name: "error text is never echoed", reply: .json(400, ["error": "Weird Text With SPACES"]), onAuthorize: rejectedRequest, onRefresh: rejectedRequest),
    TokenOutcome(name: "unreadable error body", reply: .text(400, "<html>Bad Request</html>"), onAuthorize: rejectedRequest, onRefresh: rejectedRequest),
    TokenOutcome(name: "throttled", reply: .text(429, "slow down"), onAuthorize: .rateLimited, onRefresh: .rateLimited),
    TokenOutcome(name: "server error", reply: .text(503, "unavailable"), onAuthorize: .unreachable, onRefresh: .unreachable),
    TokenOutcome(name: "connection failure", reply: .failure(URLError(.notConnectedToInternet)), onAuthorize: .unreachable, onRefresh: .unreachable),
    TokenOutcome(name: "undecodable success", reply: .text(200, "not json"), onAuthorize: .malformedResponse, onRefresh: .malformedResponse),
]

@Test(arguments: tokenOutcomes)
private func theFlowReportsTheTokenEndpointOutcomeWhenExchangingACode(outcome: TokenOutcome) async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: { _, _ in outcome.reply },
    )
    defer { harness.cleanup() }

    await #expect(throws: outcome.onAuthorize) {
        try await harness.flow.authorize()
    }
}

@Test(arguments: tokenOutcomes)
private func theFlowReportsTheTokenEndpointOutcomeWhenRefreshing(outcome: TokenOutcome) async throws {
    let harness = try SourceHarness(token: { _, _ in outcome.reply })
    defer { harness.cleanup() }

    await #expect(throws: outcome.onRefresh) {
        try await harness.flow.refresh(refreshToken: "1//stored")
    }
}

@Test func aSuccessfulRefreshReturnsTheNewAccessToken() async throws {
    let harness = try SourceHarness(token: { _, _ in .json(200, ["access_token": "fresh", "expires_in": 1800]) })
    defer { harness.cleanup() }

    let grant = try await harness.flow.refresh(refreshToken: "1//stored")

    #expect(grant.accessToken == "fresh")
    #expect(grant.expiresIn == 1800)
}
