import Foundation
@testable import GoogleCalendarSource
import Testing

// The access token lives as long as the token endpoint's `expires_in` says,
// less the source's 60-second margin. Every response here says 120, so a
// lifetime fixed at any other value changes the outcome.

private struct Elapsed: Sendable, CustomTestStringConvertible {
    let seconds: TimeInterval
    let expectedTokenRequests: Int

    var testDescription: String {
        "\(Int(seconds)) s later"
    }
}

/// 30 s leaves 90 s, more than the margin; 61 s leaves 59 s, less than it.
private let elapsedTimes = [
    Elapsed(seconds: 30, expectedTokenRequests: 1),
    Elapsed(seconds: 61, expectedTokenRequests: 2),
]

private let shortLivedToken: GoogleStub.Responder = { _, index in
    .json(200, ["access_token": "access-\(index + 1)", "expires_in": 120])
}

@Test(arguments: elapsedTimes)
private func aRefreshedAccessTokenLivesForTheExpiryTheTokenEndpointGave(elapsed: Elapsed) async throws {
    let harness = try SourceHarness(token: shortLivedToken)
    defer { harness.cleanup() }

    _ = try await harness.source.fetchActiveEvent(at: testInstant)
    harness.clock.advance(by: elapsed.seconds)
    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.count == elapsed.expectedTokenRequests)
}

@Test(arguments: elapsedTimes)
private func theAccessTokenCachedByAuthorizeLivesForTheExpiryTheTokenEndpointGave(elapsed: Elapsed) async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(expiresIn: 120),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()
    harness.clock.advance(by: elapsed.seconds)
    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.count == elapsed.expectedTokenRequests)
}
