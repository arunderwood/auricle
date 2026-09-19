import CalendarInterface
import Foundation
@testable import GoogleCalendarSource
import Testing

let readonlyScope = "https://www.googleapis.com/auth/calendar.readonly"

// MARK: - Loopback browser stand-in

func queryItems(of url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

/// What a browser does after the user consents: request the redirect URI with
/// the OAuth response in its query. Uses a plain session, so the request hits
/// the real loopback listener rather than the Google stub.
func deliverRedirect(
    for authorizationURL: URL,
    code: String? = "auth-code",
    state: String? = nil,
    error: String? = nil,
) async throws {
    let parameters = queryItems(of: authorizationURL)
    var components = try #require(URLComponents(string: parameters["redirect_uri"] ?? ""))
    components.path = "/"

    var items: [URLQueryItem] = []
    if let code {
        items.append(URLQueryItem(name: "code", value: code))
    }
    if let error {
        items.append(URLQueryItem(name: "error", value: error))
    }
    items.append(URLQueryItem(name: "state", value: state ?? parameters["state"]))
    components.queryItems = items

    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let requestURL = try #require(components.url)
    let (body, response) = try await session.data(from: requestURL)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    #expect((String(bytes: body, encoding: .utf8) ?? "").contains("close this tab"))
}

/// Collects values a `@Sendable` browser closure observes, such as the
/// authorization URL the flow asks it to open.
final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Value] = []

    func record(_ value: Value) {
        lock.lock()
        recorded.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var first: Value? {
        values.first
    }
}

typealias URLRecorder = Recorder<URL>

/// The HTTP status the loopback listener answers a plain `GET` with.
private func loopbackStatus(port: Int, pathAndQuery: String) async throws -> Int {
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    let requestURL = try #require(URL(string: "http://127.0.0.1:\(port)\(pathAndQuery)"))
    let (_, response) = try await session.data(from: requestURL)
    return try #require(response as? HTTPURLResponse).statusCode
}

/// Runs a whole `authorize()` and returns the `state` from the authorization
/// URL and the `code_verifier` sent to the token endpoint.
private func authorizeRecordingSecrets() async throws -> (state: String, verifier: String) {
    let recorder = URLRecorder()
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in
            recorder.record(url)
            try await deliverRedirect(for: url)
        },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()

    let authorizationURL = try #require(recorder.first)
    let state = try #require(queryItems(of: authorizationURL)["state"])
    let verifier = try #require(harness.stub.tokenRequests.first?.form["code_verifier"])
    return (state, verifier)
}

func grantedTokenResponse(scope: String = readonlyScope, refreshToken: String? = "1//new-refresh-token") -> GoogleStub.Responder {
    { _, _ in
        var body: [String: Any] = ["access_token": "access-from-code", "expires_in": 3600, "scope": scope, "token_type": "Bearer"]
        if let refreshToken {
            body["refresh_token"] = refreshToken
        }
        return .json(200, body)
    }
}

private func redirectPort(of authorizationURL: URL?) throws -> Int {
    let authorizationURL = try #require(authorizationURL)
    let redirectURI = try #require(queryItems(of: authorizationURL)["redirect_uri"])
    let components = try #require(URLComponents(string: redirectURI))
    return try #require(components.port)
}

private func isListenerClosed(port: Int) async -> Bool {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    for _ in 0 ..< 20 {
        do {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/?code=late&state=late")!)
        } catch {
            return true
        }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return false
}

// MARK: - PKCE

@Test func pkceChallengeMatchesTheRFC7636TestVector() {
    let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    #expect(PKCE.challenge(for: verifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@Test func pkceVerifierIsLongEnoughUsesOnlyUnreservedCharactersAndIsRandom() {
    let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let verifiers = (0 ..< 20).map { _ in PKCE.makeVerifier() }

    for verifier in verifiers {
        #expect((43 ... 128).contains(verifier.count))
        #expect(verifier.allSatisfy { unreserved.contains($0) })
    }
    #expect(Set(verifiers).count == verifiers.count)
}

@Test func pkceChallengeHasNoPaddingOrNonURLSafeCharacters() {
    for _ in 0 ..< 20 {
        let challenge = PKCE.challenge(for: PKCE.makeVerifier())
        #expect(challenge.count == 43)
        #expect(!challenge.contains("="))
        #expect(!challenge.contains("+"))
        #expect(!challenge.contains("/"))
    }
}

// MARK: - Authorization URL

@Test func authorizationURLCarriesScopeChallengeStateAndLoopbackRedirect() throws {
    let url = try GoogleOAuthFlow.authorizationURL(
        endpoint: #require(URL(string: "https://accounts.google.com/o/oauth2/v2/auth")),
        clientID: "client-123.apps.googleusercontent.com",
        redirectURI: "http://127.0.0.1:54321",
        codeChallenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
        state: "state-value",
    )

    #expect(url.scheme == "https")
    #expect(url.host == "accounts.google.com")
    #expect(url.path == "/o/oauth2/v2/auth")

    let parameters = queryItems(of: url)
    #expect(parameters["client_id"] == "client-123.apps.googleusercontent.com")
    #expect(parameters["redirect_uri"] == "http://127.0.0.1:54321")
    #expect(parameters["response_type"] == "code")
    #expect(parameters["scope"] == readonlyScope)
    #expect(parameters["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(parameters["code_challenge_method"] == "S256")
    #expect(parameters["state"] == "state-value")
    #expect(parameters["access_type"] == "offline")
    #expect(parameters["prompt"] == "consent")
}

@Test func formEncodingEscapesEverythingOutsideTheUnreservedSet() {
    let encoded = GoogleOAuthFlow.formEncoded([("a b", "x+y&z=1/é~-._")])

    #expect(encoded == "a%20b=x%2By%26z%3D1%2F%C3%A9~-._")
}

@Test func theFlowOpensAnHTTPSAuthorizationURLPointingAtAnEphemeralLoopbackPort() async throws {
    let recorder = URLRecorder()
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in
            recorder.record(url)
            try await deliverRedirect(for: url)
        },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()

    let url = try #require(recorder.first)
    let parameters = queryItems(of: url)
    #expect(url.scheme == "https")
    #expect(parameters["scope"] == readonlyScope)
    #expect(parameters["code_challenge_method"] == "S256")
    #expect(!(parameters["state"] ?? "").isEmpty)

    let redirect = try #require(URLComponents(string: parameters["redirect_uri"] ?? ""))
    #expect(redirect.scheme == "http")
    #expect(redirect.host == "127.0.0.1")
    #expect((redirect.port ?? 0) > 0)
}

// MARK: - authorize()

@Test func authorizeExchangesTheCodeWithTheVerifierAndStoresTheRefreshToken() async throws {
    let recorder = URLRecorder()
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in
            recorder.record(url)
            try await deliverRedirect(for: url, code: "the-auth-code")
        },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()

    let authorizationURL = try #require(recorder.first)
    let authorizationParameters = queryItems(of: authorizationURL)
    let exchange = try #require(harness.stub.tokenRequests.first).form
    #expect(harness.stub.tokenRequests.count == 1)
    #expect(exchange["grant_type"] == "authorization_code")
    #expect(exchange["code"] == "the-auth-code")
    #expect(exchange["client_id"] == "test-client.apps.googleusercontent.com")
    #expect(exchange["redirect_uri"] == authorizationParameters["redirect_uri"])
    #expect(exchange["client_secret"] == nil)

    let verifier = try #require(exchange["code_verifier"])
    #expect(PKCE.challenge(for: verifier) == authorizationParameters["code_challenge"])

    #expect(harness.storedRefreshToken == "1//new-refresh-token")
}

@Test func everyAuthorizationUsesAFreshStateAndVerifier() async throws {
    let first = try await authorizeRecordingSecrets()
    let second = try await authorizeRecordingSecrets()

    #expect(first.state != second.state)
    #expect(first.verifier != second.verifier)
    #expect(first.state != first.verifier)
}

@Test func theListenerAnswersNonOAuthAndRepeatRequestsWith404WhileWaitingForTheRealRedirect() async throws {
    let statuses = Recorder<Int>()
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in
            let port = try redirectPort(of: url)
            let state = try #require(queryItems(of: url)["state"])

            try await statuses.record(loopbackStatus(port: port, pathAndQuery: "/favicon.ico"))
            try await deliverRedirect(for: url, code: "auth-code")
            try await statuses.record(loopbackStatus(port: port, pathAndQuery: "/?code=intruder&state=\(state)"))
        },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()

    #expect(statuses.values == [404, 404])
    #expect(harness.stub.tokenRequests.count == 1)
    #expect(harness.stub.tokenRequests.first?.form["code"] == "auth-code")
    #expect(harness.storedRefreshToken == "1//new-refresh-token")
}

@Test func authorizeSendsTheClientSecretOnlyWhenTheClientHasOne() async throws {
    let harness = try SourceHarness(
        client: GoogleOAuthClient(clientID: "id", clientSecret: "shh-secret"),
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()

    #expect(harness.stub.tokenRequests.first?.form["client_secret"] == "shh-secret")
}

@Test func authorizeReplacesAnExistingRefreshToken() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: "1//old-revoked-token",
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()

    #expect(harness.storedRefreshToken == "1//new-refresh-token")
}

@Test func authorizeKeepsTheAccessTokenInMemoryForTheNextCall() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(),
        events: { _, _ in eventList([]) },
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()
    _ = try await harness.source.fetchActiveEvent(at: testInstant)

    #expect(harness.stub.tokenRequests.count == 1)
    #expect(harness.stub.eventRequests.first?.bearerToken == "access-from-code")
}

@Test func authorizeFailsWhenTheRedirectEchoesADifferentState() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url, state: "forged-state") },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
    #expect(harness.stub.tokenRequests.isEmpty)
}

@Test func authorizeFailsWhenTheUserDeniesAccess() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url, code: nil, error: "access_denied") },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
    #expect(harness.stub.tokenRequests.isEmpty)
}

@Test func authorizeFailsWhenTheRedirectCarriesNoCode() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url, code: nil, error: "server_error") },
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }
    #expect(harness.stub.tokenRequests.isEmpty)
}

@Test func authorizeTimesOutAndClosesTheListenerWhenNoRedirectArrives() async throws {
    let recorder = URLRecorder()
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        redirectTimeout: .milliseconds(200),
        openBrowser: { url in recorder.record(url) },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }

    #expect(harness.storedRefreshToken == nil)
    #expect(harness.stub.tokenRequests.isEmpty)
    let port = try redirectPort(of: recorder.first)
    #expect(await isListenerClosed(port: port))
}

@Test func authorizeClosesTheListenerAfterASuccessfulRedirect() async throws {
    let recorder = URLRecorder()
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in
            recorder.record(url)
            try await deliverRedirect(for: url)
        },
        token: grantedTokenResponse(),
    )
    defer { harness.cleanup() }

    try await harness.source.authorize()

    let port = try redirectPort(of: recorder.first)
    #expect(await isListenerClosed(port: port))
}

@Test func authorizeFailsWhenTheBrowserCannotBeOpened() async throws {
    struct NoBrowser: Error {}
    let harness = try SourceHarness(storedRefreshToken: nil, openBrowser: { _ in throw NoBrowser() })
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
}

@Test func authorizeFailsWhenTheTokenResponseDoesNotGrantTheCalendarScope() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(scope: "openid email"),
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
}

@Test func authorizeRejectsAScopeThatOnlyContainsTheCalendarScopeAsASubstring() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(scope: readonlyScope + ".extra"),
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
}

@Test func authorizeFailsWhenTheTokenResponseHasNoRefreshToken() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: grantedTokenResponse(refreshToken: nil),
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
}

@Test func authorizeFailsWhenGoogleRejectsTheCode() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: { _, _ in .json(400, ["error": "invalid_grant", "error_description": "Bad Request"]) },
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.authorizationExpired) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
}

@Test func authorizeSurfacesAnUnreachableTokenEndpoint() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: { _, _ in .failure(URLError(.notConnectedToInternet)) },
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
}

@Test func authorizeReportsAnUndecodableTokenResponseAsUnreachable() async throws {
    let harness = try SourceHarness(
        storedRefreshToken: nil,
        openBrowser: { url in try await deliverRedirect(for: url) },
        token: { _, _ in .text(200, "not json") },
    )
    defer { harness.cleanup() }

    await #expect(throws: CalendarError.unreachable) {
        try await harness.source.authorize()
    }
    #expect(harness.storedRefreshToken == nil)
}

// MARK: - Loopback request parsing

@Test func loopbackParserAcceptsOnlyAGETCarryingAnOAuthResponse() {
    #expect(LoopbackRedirectListener.oauthQueryItems(fromRequestLine: "GET /?code=abc&state=xyz HTTP/1.1")?.count == 2)
    #expect(LoopbackRedirectListener.oauthQueryItems(fromRequestLine: "GET /?error=access_denied&state=xyz HTTP/1.1")?.count == 2)
    #expect(LoopbackRedirectListener.oauthQueryItems(fromRequestLine: "GET /favicon.ico HTTP/1.1") == nil)
    #expect(LoopbackRedirectListener.oauthQueryItems(fromRequestLine: "GET /?other=1 HTTP/1.1") == nil)
    #expect(LoopbackRedirectListener.oauthQueryItems(fromRequestLine: "POST /?code=abc HTTP/1.1") == nil)
    #expect(LoopbackRedirectListener.oauthQueryItems(fromRequestLine: "garbage") == nil)
}

@Test func loopbackParserDecodesPercentEncodedValues() {
    let items = LoopbackRedirectListener.oauthQueryItems(fromRequestLine: "GET /?code=4%2F0AbC&state=s HTTP/1.1")

    #expect(items?.first { $0.name == "code" }?.value == "4/0AbC")
}

// MARK: - Endpoints

@Test func endpointsRejectAnInsecureSchemeWithAPrecondition() async throws {
    await #expect(processExitsWith: .failure) {
        _ = try GoogleEndpoints(
            authorization: #require(URL(string: "https://accounts.example/auth")),
            token: #require(URL(string: "http://insecure.example/token")),
            calendarAPI: #require(URL(string: "https://api.example/calendar/v3")),
        )
    }
}

@Test func endpointsAcceptAnHTTPSOverride() async throws {
    await #expect(processExitsWith: .success) {
        _ = try GoogleEndpoints(
            authorization: #require(URL(string: "https://accounts.example/auth")),
            token: #require(URL(string: "https://oauth.example/token")),
            calendarAPI: #require(URL(string: "https://api.example/calendar/v3")),
        )
    }
}

@Test func productionEndpointsAreAllHTTPS() {
    let endpoints = GoogleEndpoints.production

    #expect(endpoints.authorization.scheme == "https")
    #expect(endpoints.token.scheme == "https")
    #expect(endpoints.calendarAPI.scheme == "https")
}

@Test func theDefaultSessionRequiresTLS12OrNewer() {
    let configuration = GoogleCalendarSource.makeDefaultSession().configuration

    #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
}
